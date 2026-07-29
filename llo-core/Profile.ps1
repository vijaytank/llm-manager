# LLO Hardware Profiler v2
# Two-step GPU classification:
#   AdapterClass:    none | integrated | dedicated
#   PerformanceTier: cpu  | low        | mid       | high
#
# AdapterClass describes the hardware type (discrete vs shared-memory).
# PerformanceTier drives the inference parameter policy in SetupRouter.ps1.
# These are intentionally orthogonal: a 2 GB MX card is "dedicated" class
# but "cpu" tier (dedicated hw, but too little VRAM for useful offload).
#
# Platform support:
#   Windows : WMI (Win32_Processor/ComputerSystem/VideoController) + nvidia-smi
#   macOS   : sysctl + system_profiler (Apple Silicon unified memory or discrete GPU)
#   Linux   : /proc/cpuinfo, /proc/meminfo, nvidia-smi, rocm-smi, /sys/class/drm

param(
    [switch]$Json
)

$isWin = $IsWindows -or ($env:OS -match "Windows") -or ($PSVersionTable.PSEdition -eq "Desktop")
$isMac = $IsMacOS -or ($env:OSTYPE -match "darwin")
$isLin = $IsLinux -or (-not $isWin -and -not $isMac)

$ErrorActionPreference = "Stop"

function Get-SystemHardwareProfile {
    if (-not $Json) {
        Write-Host "Profiling system hardware..." -ForegroundColor Cyan
    }

    # ── 1. CPU ────────────────────────────────────────────────────────────────
    $cpuName       = "Unknown"
    $logicalCores  = 1
    $physicalCores = 1

    if ($isWin) {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors
        $cpuName       = $cpu.Name.Trim()
        $logicalCores  = $cpu.NumberOfLogicalProcessors
        $physicalCores = $cpu.NumberOfCores
    } elseif ($isMac) {
        try {
            $cpuName      = (sysctl -n machdep.cpu.brand_string 2>$null).Trim()
            if ([string]::IsNullOrWhiteSpace($cpuName)) { $cpuName = (sysctl -n hw.model 2>$null).Trim() }
            $physicalCores = [int](sysctl -n hw.physicalcpu 2>$null)
            $logicalCores  = [int](sysctl -n hw.logicalcpu  2>$null)
        } catch {
            if (-not $Json) { Write-Host "[WARNING] macOS CPU detection failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    } elseif ($isLin) {
        try {
            $cpuInfo = Get-Content /proc/cpuinfo -ErrorAction SilentlyContinue
            if ($cpuInfo) {
                $modelLine = $cpuInfo | Where-Object { $_ -match '^model name' } | Select-Object -First 1
                if ($modelLine -match ':\s*(.+)') { $cpuName = $Matches[1].Trim() }
                $physicalCoresLine = $cpuInfo | Where-Object { $_ -match '^cpu cores' } | Select-Object -First 1
                if ($physicalCoresLine -match ':\s*(\d+)') { $physicalCores = [int]$Matches[1] }
                $logicalCores = @($cpuInfo | Where-Object { $_ -match '^processor\s+:' }).Count
                if ($logicalCores -lt 1) { $logicalCores = $physicalCores }
            }
        } catch {
            if (-not $Json) { Write-Host "[WARNING] Linux CPU detection failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }

    # Intel Hybrid Architecture heuristic (Core Ultra, Alder Lake+):
    # Recommend P-core count only, capped at 8, to avoid E-core scheduling overhead.
    $optimalThreads = $physicalCores
    if ($cpuName -match "Intel" -and $physicalCores -gt 8) {
        $optimalThreads = 8
    }
    if ($optimalThreads -lt 4) { $optimalThreads = 4 }

    # ── 2. RAM ────────────────────────────────────────────────────────────────
    $totalRamBytes = 0

    if ($isWin) {
        $cs            = Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory
        $totalRamBytes = $cs.TotalPhysicalMemory
    } elseif ($isMac) {
        try {
            $totalRamBytes = [long](sysctl -n hw.memsize 2>$null)
        } catch {
            if (-not $Json) { Write-Host "[WARNING] macOS RAM detection failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    } elseif ($isLin) {
        try {
            $memInfo = Get-Content /proc/meminfo -ErrorAction SilentlyContinue
            $memTotalLine = $memInfo | Where-Object { $_ -match '^MemTotal' } | Select-Object -First 1
            if ($memTotalLine -match ':\s*(\d+)\s*kB') {
                $totalRamBytes = [long]$Matches[1] * 1024
            }
        } catch {
            if (-not $Json) { Write-Host "[WARNING] Linux RAM detection failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }

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
    if ($isWin) {
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
    } else {
        # macOS / Linux: nvidia-smi lives in standard Unix paths
        $smiCandidates = @(
            "/usr/bin/nvidia-smi",
            "/usr/local/bin/nvidia-smi",
            "/opt/homebrew/bin/nvidia-smi"
        )
        foreach ($p in $smiCandidates) {
            if (Test-Path $p) { $nvidiaSmi = $p; break }
        }
        if (-not $nvidiaSmi) {
            $found = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
            if ($found) { $nvidiaSmi = $found.Source }
        }
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

    # ── WMI fallback (Intel/AMD/Arc or NVIDIA when smi failed) — Windows only ──
    if ($IsWindows -and (-not $hasNvidiaSmi -or $totalVramMB -eq 0)) {
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

    # ── macOS GPU fallback (Apple Silicon or discrete GPU via system_profiler) ──
    if ($IsMacOS -and -not $hasNvidiaSmi) {
        try {
            # Use system_profiler JSON output for reliable parsing
            $spRaw = & system_profiler SPDisplaysDataType -json 2>$null | ConvertFrom-Json
            $displays = $spRaw.SPDisplaysDataType

            if ($displays -and $displays.Count -gt 0) {
                $gpuEntry = $displays[0]
                $gpuName  = $gpuEntry.sppci_model
                if ([string]::IsNullOrWhiteSpace($gpuName)) { $gpuName = $gpuEntry._name }

                # Apple Silicon (M-series): GPU shares system RAM (unified memory).
                # The entire RAM budget is available for inference — treat as dedicated-class.
                $isAppleSilicon = ($gpuName -match "Apple M" -or $gpuName -match "Apple GPU")

                if ($isAppleSilicon) {
                    # Unified memory: use system RAM as the VRAM budget
                    $totalVramMB        = $totalRamMB
                    $freeVramMB         = $totalRamMB
                    $adapterClass       = "dedicated"   # M-series GPU is discrete in performance terms
                    $usableForInference = $true
                    $hasCudaBackend     = $false        # Metal, not CUDA
                    $hasVulkanBackend   = $false
                    Write-Host "  [Apple Silicon] Unified memory GPU detected: $gpuName ($([math]::Round($totalVramMB/1024,1)) GB)" -ForegroundColor Cyan
                } else {
                    # Discrete AMD/NVIDIA GPU on an Intel Mac
                    $vramStr = $gpuEntry.sppci_vram
                    if ($vramStr -match '(\d+)\s*MB') {
                        $totalVramMB = [int]$Matches[1]
                        $freeVramMB  = $totalVramMB
                    } elseif ($vramStr -match '(\d+)\s*GB') {
                        $totalVramMB = [int]$Matches[1] * 1024
                        $freeVramMB  = $totalVramMB
                    }
                    $adapterClass       = if ($totalVramMB -gt 0) { "dedicated" } else { "integrated" }
                    $usableForInference = ($adapterClass -eq "dedicated" -and $totalVramMB -gt 0)
                }
            }
        } catch {
            Write-Host "[WARNING] macOS GPU detection failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # ── Linux GPU fallback (AMD rocm-smi or sysfs when nvidia-smi not available) ─
    if ($IsLinux -and -not $hasNvidiaSmi) {
        # Try rocm-smi for AMD GPUs
        $rocmSmi = Get-Command "rocm-smi" -ErrorAction SilentlyContinue
        if ($rocmSmi) {
            try {
                $rocmJson = & rocm-smi --showmeminfo vram --json 2>$null | ConvertFrom-Json
                if ($rocmJson) {
                    # rocm-smi JSON structure: { "card0": { "VRAM Total Memory (B)": "...", "VRAM Total Used Memory (B)": "..." } }
                    $firstCard = $rocmJson.PSObject.Properties | Select-Object -First 1
                    if ($firstCard) {
                        $vramTotalBytes = [long]($firstCard.Value.'VRAM Total Memory (B)')
                        $vramUsedBytes  = [long]($firstCard.Value.'VRAM Total Used Memory (B)')
                        if ($vramTotalBytes -gt 0) {
                            $totalVramMB        = [math]::Round($vramTotalBytes / 1MB, 0)
                            $freeVramMB         = [math]::Round(($vramTotalBytes - $vramUsedBytes) / 1MB, 0)
                            $adapterClass       = "dedicated"
                            $usableForInference = $true
                            # Read GPU name from rocm-smi --showproductname
                            $nameRaw = & rocm-smi --showproductname 2>$null
                            if ($nameRaw -match 'Card series:\s*(.+)') { $gpuName = $Matches[1].Trim() }
                            elseif ($nameRaw -match 'GPU\[\d+\].*?:\s*(.+)') { $gpuName = $Matches[1].Trim() }
                            Write-Host "  [AMD ROCm] Detected: $gpuName ($([math]::Round($totalVramMB/1024,1)) GB VRAM)" -ForegroundColor Cyan
                        }
                    }
                }
            } catch {
                Write-Host "[WARNING] rocm-smi query failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # sysfs fallback for any GPU (DRM subsystem exposes VRAM sizes)
        if ($totalVramMB -eq 0) {
            try {
                $drmCards = Get-ChildItem /sys/class/drm -Filter 'card*' -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^card\d+$' }
                foreach ($card in $drmCards) {
                    $vramFile = Join-Path $card.FullName "device/mem_info_vram_total"
                    if (Test-Path $vramFile) {
                        $vramBytes = [long](Get-Content $vramFile -Raw).Trim()
                        if ($vramBytes -gt 0) {
                            $totalVramMB        = [math]::Round($vramBytes / 1MB, 0)
                            $freeVramMB         = $totalVramMB   # sysfs total only
                            $adapterClass       = "dedicated"
                            $usableForInference = ($totalVramMB -ge 2048)
                            # Try to get GPU name from vendor/uevent
                            $ueventFile = Join-Path $card.FullName "device/uevent"
                            if (Test-Path $ueventFile) {
                                $uevent = Get-Content $ueventFile -Raw
                                if ($uevent -match 'PCI_ID=([0-9A-Fa-f:]+)') { $gpuName = "GPU (PCI $($Matches[1]))" }
                            }
                            break
                        }
                    }
                }
            } catch {
                Write-Host "[WARNING] Linux sysfs GPU detection failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Intel integrated GPU detection on Linux (no VRAM file, CPU-tier)
        if ($totalVramMB -eq 0) {
            try {
                $i915 = Get-ChildItem /sys/class/drm -Filter 'card*' -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.FullName "device/driver/module/drivers/pci:i915") }
                if ($i915) {
                    $gpuName      = "Intel Integrated Graphics"
                    $adapterClass = "integrated"
                }
            } catch {}
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
if ($Json) {
    $p = Get-SystemHardwareProfile
    $p | ConvertTo-Json -Depth 5
} elseif ($MyInvocation.MyCommand.Name -eq 'Profile.ps1') {
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
