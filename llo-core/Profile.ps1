# LLO Hardware Profiler
# Dynamically detects CPU, RAM, and GPU/VRAM to calculate an optimal inference budget.

$ErrorActionPreference = "Stop"

function Get-SystemHardwareProfile {
    Write-Host "Profiling system hardware..." -ForegroundColor Cyan

    # 1. CPU Profiling
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors
    $cpuName = $cpu.Name.Trim()
    $logicalCores = $cpu.NumberOfLogicalProcessors
    $physicalCores = $cpu.NumberOfCores

    # Intel Hybrid Architecture heuristic (Core Ultra, Alder Lake, etc.)
    # Recommend threads equal to physical cores, capped at 12 to prevent scheduling overhead on E-cores
    $optimalThreads = $physicalCores
    if ($cpuName -match "Intel" -and $physicalCores -gt 8) {
        $optimalThreads = 8 # Sweet spot for Core Ultra / Core i7 P-cores
    }
    if ($optimalThreads -lt 4) { $optimalThreads = 4 }

    # 2. RAM Profiling
    $cs = Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory
    $totalRamBytes = $cs.TotalPhysicalMemory
    $totalRamMB = [math]::Round($totalRamBytes / 1MB, 0)
    $totalRamGB = [math]::Round($totalRamBytes / 1GB, 1)

    # Reserve 6GB for OS/Apps, use the rest up to 80%
    $safeRamMB = [math]::Round(($totalRamMB - 6144), 0)
    if ($safeRamMB -lt 4096) { $safeRamMB = 4096 }

    # 3. GPU / VRAM Profiling (NVIDIA CUDA focus)
    $gpuName = "CPU Only"
    $totalVramMB = 0
    $vmmSupported = $false
    $cudaVersion = "N/A"

    # Attempt to locate nvidia-smi.exe
    $nvidiaSmi = "nvidia-smi.exe"
    $pathsToCheck = @(
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "C:\Windows\System32\nvidia-smi.exe"
    )
    foreach ($p in $pathsToCheck) {
        if (Test-Path $p) { $nvidiaSmi = $p; break }
    }

    try {
        # Query GPU name and VRAM via nvidia-smi
        $smiOut = & $nvidiaSmi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null
        if ($smiOut -and $smiOut -match ",") {
            $parts = $smiOut -split ","
            $gpuName = $parts[0].Trim()
            $totalVramMB = [double]($parts[1].Trim())
            $cudaVersion = $parts[2].Trim()
            $vmmSupported = $true
        }
    } catch {
        # Fallback to WMI for GPU name if nvidia-smi fails
        try {
            $wmiGpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "NVIDIA" } | Select-Object -First 1
            if ($wmiGpu) {
                $gpuName = $wmiGpu.Name
                # WMI AdapterRAM is often reported incorrectly for modern cards, use basic 8GB heuristic if empty
                $totalVramMB = if ($wmiGpu.AdapterRAM) { [math]::Round($wmiGpu.AdapterRAM / 1MB, 0) } else { 8192 }
            }
        } catch {}
    }

    # Calculate VRAM budget: Reserve 1.5GB for OS/Display outputs
    $safeVramMB = 0
    if ($totalVramMB -gt 0) {
        $safeVramMB = [math]::Round(($totalVramMB - 1536), 0)
        if ($safeVramMB -lt 1024) { $safeVramMB = 1024 }
    }

    $profile = [pscustomobject]@{
        CPU = @{
            Name = $cpuName
            PhysicalCores = $physicalCores
            LogicalCores = $logicalCores
            OptimalThreads = $optimalThreads
        }
        RAM = @{
            TotalGB = $totalRamGB
            TotalMB = $totalRamMB
            BudgetMB = $safeRamMB
        }
        GPU = @{
            Name = $gpuName
            TotalVramMB = $totalVramMB
            BudgetVramMB = $safeVramMB
            CudaDriver = $cudaVersion
            VmmSupported = $vmmSupported
        }
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    return $profile
}

# If run directly, print profile summary
if ($MyInvocation.InvocationName -eq '.' -or $MyInvocation.InvocationName -eq '&' -or $MyInvocation.MyCommand.Name -eq 'Profile.ps1') {
    $p = Get-SystemHardwareProfile
    Write-Host "--- System Hardware Profile ---" -ForegroundColor Green
    Write-Host "CPU: $($p.CPU.Name) ($($p.CPU.PhysicalCores) cores)"
    Write-Host "Optimal Inference Threads: $($p.CPU.OptimalThreads)"
    Write-Host "RAM: $($p.RAM.TotalGB) GB (Allocation Budget: $($p.RAM.BudgetMB) MB)"
    Write-Host "GPU: $($p.GPU.Name) ($([math]::Round($p.GPU.TotalVramMB/1024, 1)) GB VRAM)"
    Write-Host "VRAM Allocation Budget: $($p.GPU.BudgetVramMB) MB"
    Write-Host "-------------------------------"
}
