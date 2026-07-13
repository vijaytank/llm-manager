# LLO Hardware Profiler v2
# Two-step GPU classification:
#   AdapterClass:    none | integrated | dedicated
#   PerformanceTier: cpu  | low        | mid       | high
#
# AdapterClass describes the hardware type (discrete vs shared-memory).
# PerformanceTier drives the inference parameter policy in SetupRouter.ps1.
# These are intentionally orthogonal: a 2 GB MX card is "dedicated" class
# but "cpu" tier (dedicated hw, but too little VRAM for useful offload).

$ErrorActionPreference = "Stop"

function Get-SystemHardwareProfile {
    Write-Host "Profiling system hardware..." -ForegroundColor Cyan

    # ── 1. CPU ────────────────────────────────────────────────────────────────
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors
    $cpuName       = $cpu.Name.Trim()
    $logicalCores  = $cpu.NumberOfLogicalProcessors
    $physicalCores = $cpu.NumberOfCores

    # Intel Hybrid Architecture heuristic (Core Ultra, Alder Lake+):
    # Recommend P-core count only, capped at 8, to avoid E-core scheduling overhead.
    $optimalThreads = $physicalCores
    if ($cpuName -match "Intel" -and $physicalCores -gt 8) {
        $optimalThreads = 8
    }
    if ($optimalThreads -lt 4) { $optimalThreads = 4 }

    # ── 2. RAM ────────────────────────────────────────────────────────────────
    $cs            = Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory
    $totalRamBytes = $cs.TotalPhysicalMemory
    $totalRamMB    = [math]::Round($totalRamBytes / 1MB, 0)
    $totalRamGB    = [math]::Round($totalRamBytes / 1GB, 1)

    # Reserve 6 GB for OS + apps; floor at 4 GB minimum budget
    $safeRamMB = [math]::Round(($totalRamMB - 6144), 0)
    if ($safeRamMB -lt 4096) { $safeRamMB = 4096 }

    # ── 3. GPU ────────────────────────────────────────────────────────────────
    $gpuName            = "None"
    $totalVramMB        = 0
    $freeVramMB         = 0
    $adapterClass       = "none"
    $performanceTier    = "cpu"
    $tierReason         = "No GPU detected - CPU-only inference"
    $hasNvidiaSmi       = $false
    $hasCudaBackend     = $false
    $hasVulkanBackend   = $false   # future: check vulkaninfo / DX12 caps
    $usableForInference = $false
    $cudaDriver         = "N/A"
    $budgetVramMB       = 0

    # Locate nvidia-smi (prefer explicit paths, fall back to PATH lookup)
    $nvidiaSmi = $null
    $smiCandidates = @(
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "C:\Windows\System32\nvidia-smi.exe"
    )
    foreach ($p in $smiCandidates) {
        if (Test-Path $p) { $nvidiaSmi = $p; break }
    }
    if (-not $nvidiaSmi) {
        $found = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
        if ($found) { $nvidiaSmi = $found.Source }
    }

    # ── nvidia-smi path (NVIDIA CUDA) ─────────────────────────────────────────
    if ($nvidiaSmi) {
        try {
            # Query all GPUs: name, total VRAM, free VRAM, driver version
            $smiRaw = & $nvidiaSmi `
                --query-gpu=name,memory.total,memory.free,driver_version `
                --format=csv,noheader,nounits 2>$null

            if ($smiRaw) {
                $hasNvidiaSmi       = $true
                $hasCudaBackend     = $true
                $usableForInference = $true

                # Multi-GPU: pick the device with the most free VRAM
                $bestGpu    = $null
                $bestFreeMB = -1

                foreach ($line in @($smiRaw)) {
                    $line = $line.Trim()
                    if ([string]::IsNullOrEmpty($line)) { continue }
                    $parts = $line -split ","
                    if ($parts.Count -lt 4) { continue }

                    $gName   = $parts[0].Trim()
                    $gTotal  = [double]($parts[1].Trim())
                    $gFree   = [double]($parts[2].Trim())
                    $gDriver = $parts[3].Trim()

                    if ($gFree -gt $bestFreeMB) {
                        $bestFreeMB = $gFree
                        $bestGpu = @{
                            Name   = $gName
                            Total  = [int]$gTotal
                            Free   = [int]$gFree
                            Driver = $gDriver
                        }
                    }
                }

                if ($bestGpu) {
                    $gpuName      = $bestGpu.Name
                    $totalVramMB  = $bestGpu.Total
                    $freeVramMB   = $bestGpu.Free
                    $cudaDriver   = $bestGpu.Driver
                    $adapterClass = "dedicated"   # nvidia-smi only sees discrete GPUs
                }
            }
        } catch {
            # nvidia-smi present but failed; treat as unavailable
            $hasNvidiaSmi = $false
        }
    }

    # ── WMI fallback (Intel/AMD/Arc or NVIDIA when smi failed) ────────────────
    if (-not $hasNvidiaSmi -or $totalVramMB -eq 0) {
        try {
            $allControllers = @(Get-CimInstance Win32_VideoController |
                Where-Object { $_.Name -match "NVIDIA|AMD|Radeon|Intel|Arc" })

            if ($allControllers.Count -gt 0) {
                # Dual-GPU laptop heuristic:
                # Shared/integrated GPUs report AdapterRAM ≈ system RAM (they borrow it).
                # Dedicated GPUs have their own onboard memory, which will NOT be close to totalRamBytes.
                # Threshold: if AdapterRAM differs from system RAM by less than 256 MB → shared memory.
                $sharedMemThreshold = 256MB

                $dedicatedCandidates = @($allControllers | Where-Object {
                    $_.AdapterRAM -and
                    $_.AdapterRAM -gt 1MB -and
                    [math]::Abs($_.AdapterRAM - $totalRamBytes) -gt $sharedMemThreshold
                })

                # Prefer dedicated adapter; fall back to first available
                $wmiGpu = if ($dedicatedCandidates.Count -gt 0) {
                    $dedicatedCandidates[0]
                } else {
                    $allControllers[0]
                }

                if ($wmiGpu) {
                    $gpuName  = $wmiGpu.Name
                    $rawVram  = $wmiGpu.AdapterRAM
                    $isShared = ($rawVram -and [math]::Abs($rawVram - $totalRamBytes) -lt $sharedMemThreshold)

                    if ($rawVram -and $rawVram -gt 1MB) {
                        $totalVramMB = [math]::Round($rawVram / 1MB, 0)
                        $freeVramMB  = $totalVramMB   # WMI cannot report free VRAM
                    }

                    # Integrated GPU name patterns (conservative — Arc excluded, it can be discrete)
                    # Intel UHD / Iris / HD Graphics = integrated
                    # AMD Radeon without "RX" = iGPU (RX series are discrete)
                    $isIGPUByName = (
                        $gpuName -match "Intel.*(UHD|Iris|HD\s+Graphics)" -or
                        ($gpuName -match "AMD.*Radeon" -and $gpuName -notmatch "\bRX\b")
                    )

                    $adapterClass = if ($isShared -or $isIGPUByName) { "integrated" } else { "dedicated" }

                    # WMI-discovered GPU has no proven inference backend
                    # Mark usable only if it appears to be a real discrete card
                    $usableForInference = ($adapterClass -eq "dedicated" -and $totalVramMB -gt 0)
                }
            }
        } catch {
            Write-Host "[WARNING] WMI GPU query failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # ── 4. Derive PerformanceTier ─────────────────────────────────────────────
    # Reserve 1 GB of VRAM for OS/display driver; floor at 1 GB minimum budget
    if ($totalVramMB -gt 0) {
        $budgetVramMB = [math]::Max($totalVramMB - 1024, 1024)
    }

    if ($adapterClass -eq "none") {
        $performanceTier = "cpu"
        $tierReason      = "No GPU detected - CPU-only inference"
    }
    elseif ($adapterClass -eq "integrated") {
        $performanceTier = "cpu"
        $tierReason      = "Integrated/shared-memory GPU ($gpuName) - CPU path delivers better throughput"
    }
    elseif (-not $usableForInference) {
        $performanceTier = "cpu"
        $tierReason      = "No compatible inference backend (CUDA/Vulkan) found for $gpuName - CPU-only inference"
    }
    elseif ($totalVramMB -le 2048) {
        $performanceTier = "cpu"
        $tierReason      = "Dedicated GPU VRAM $([math]::Round($totalVramMB/1024,1)) GB is below 2 GB threshold - CPU-only avoids slow VRAM spill"
    }
    elseif ($totalVramMB -le 4096) {
        $performanceTier = "low"
        $tierReason      = "Dedicated GPU ~$([math]::Round($totalVramMB/1024,1)) GB VRAM - partial offload with fit-throttle"
    }
    elseif ($totalVramMB -le 8192) {
        $performanceTier = "mid"
        $tierReason      = "Dedicated GPU ~$([math]::Round($totalVramMB/1024,1)) GB VRAM - full offload for small-mid models"
    }
    else {
        $performanceTier = "high"
        $tierReason      = "Dedicated GPU ~$([math]::Round($totalVramMB/1024,1)) GB VRAM - full offload, large context available"
    }

    # ── 5. Build profile object ───────────────────────────────────────────────
    $profile = [pscustomobject]@{
        CPU = @{
            Name           = $cpuName
            PhysicalCores  = $physicalCores
            LogicalCores   = $logicalCores
            OptimalThreads = $optimalThreads
        }
        RAM = @{
            TotalGB  = $totalRamGB
            TotalMB  = $totalRamMB
            BudgetMB = $safeRamMB
        }
        GPU = @{
            # Hardware identity
            Name         = $gpuName
            AdapterClass = $adapterClass       # none | integrated | dedicated
            TotalVramMB  = $totalVramMB
            FreeVramMB   = $freeVramMB
            BudgetVramMB = $budgetVramMB
            CudaDriver   = $cudaDriver

            # Backend availability
            HasNvidiaSmi       = $hasNvidiaSmi
            HasCudaBackend     = $hasCudaBackend
            HasVulkanBackend   = $hasVulkanBackend   # always false in v1 (no Vulkan probe yet)
            UsableForInference = $usableForInference

            # Inference policy
            PerformanceTier = $performanceTier   # cpu | low | mid | high
            TierReason      = $tierReason
        }
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    return $profile
}

# ── Self-run: print summary when executed directly (not dot-sourced) ──────────
# Using MyCommand.Name is safe for nested dot-sourcing: it reflects the
# script file name only when run directly, not when dot-sourced into another scope.
if ($MyInvocation.MyCommand.Name -eq 'Profile.ps1') {
    $p = Get-SystemHardwareProfile
    Write-Host ""
    Write-Host "--- System Hardware Profile ---" -ForegroundColor Green
    Write-Host "CPU  : $($p.CPU.Name)"
    Write-Host "       $($p.CPU.PhysicalCores) physical cores → $($p.CPU.OptimalThreads) inference threads"
    Write-Host "RAM  : $($p.RAM.TotalGB) GB total  |  $($p.RAM.BudgetMB) MB safe budget"
    Write-Host "GPU  : $($p.GPU.Name)"
    Write-Host "       Class       : $($p.GPU.AdapterClass)"
    if ($p.GPU.TotalVramMB -gt 0) {
        Write-Host "       VRAM        : $([math]::Round($p.GPU.TotalVramMB/1024,1)) GB total  |  $([math]::Round($p.GPU.FreeVramMB/1024,1)) GB free"
    }
    Write-Host "       CUDA        : $(if ($p.GPU.HasCudaBackend) { 'AVAILABLE (driver ' + $p.GPU.CudaDriver + ')' } else { 'not available' })"
    Write-Host "       Tier        : $($p.GPU.PerformanceTier.ToUpper())"
    Write-Host "       Reason      : $($p.GPU.TierReason)"
    Write-Host "-------------------------------"
}
