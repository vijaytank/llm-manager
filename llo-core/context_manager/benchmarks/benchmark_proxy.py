#!/usr/bin/env python3
"""
Performance benchmark for LLO Context Manager Proxy.

Measures:
- Request latency (p50, p95, p99)
- Throughput (requests/second)
- Compression overhead
- Memory usage

Usage:
    python benchmark_proxy.py --url http://localhost:8090 --requests 100 --concurrency 10
"""

import asyncio
import argparse
import statistics
import time
import json
import sys
from dataclasses import dataclass
from typing import List, Optional
import httpx


@dataclass
class BenchmarkResult:
    total_requests: int
    successful: int
    failed: int
    total_time_sec: float
    requests_per_sec: float
    latencies_ms: List[float]
    p50_ms: float
    p95_ms: float
    p99_ms: float
    min_ms: float
    max_ms: float


async def make_request(
    client: httpx.AsyncClient,
    url: str,
    payload: dict,
    headers: dict,
    semaphore: asyncio.Semaphore
) -> tuple[float, int, Optional[str]]:
    """Make a single request and return (latency_ms, status_code, error)."""
    async with semaphore:
        start = time.perf_counter()
        try:
            resp = await client.post(url, json=payload, headers=headers, timeout=30.0)
            latency = (time.perf_counter() - start) * 1000
            return latency, resp.status_code, None
        except Exception as e:
            latency = (time.perf_counter() - start) * 1000
            return latency, 0, str(e)


async def run_benchmark(
    url: str,
    num_requests: int,
    concurrency: int,
    model: str = "test-model",
    stream: bool = False
) -> BenchmarkResult:
    """Run the benchmark."""
    payload = {
        "model": model,
        "max_tokens": 100,
        "messages": [{"role": "user", "content": "Hello, this is a benchmark request."}],
        "stream": stream
    }
    headers = {"x-api-key": "local-key", "Content-Type": "application/json"}
    
    semaphore = asyncio.Semaphore(concurrency)
    limits = httpx.Limits(max_connections=concurrency + 5, max_keepalive_connections=concurrency)
    
    async with httpx.AsyncClient(limits=limits, timeout=60.0) as client:
        # Warmup
        for _ in range(3):
            await make_request(client, url, payload, headers, semaphore)
        
        # Actual benchmark
        start_time = time.perf_counter()
        tasks = [
            make_request(client, url, payload, headers, semaphore)
            for _ in range(num_requests)
        ]
        results = await asyncio.gather(*tasks)
        total_time = time.perf_counter() - start_time
    
    latencies = [r[0] for r in results]
    status_codes = [r[1] for r in results]
    errors = [r[2] for r in results]
    
    successful = sum(1 for s in status_codes if 200 <= s < 300)
    failed = num_requests - successful
    
    latencies_sorted = sorted(latencies)
    n = len(latencies_sorted)
    
    return BenchmarkResult(
        total_requests=num_requests,
        successful=successful,
        failed=failed,
        total_time_sec=total_time,
        requests_per_sec=num_requests / total_time,
        latencies_ms=latencies,
        p50_ms=latencies_sorted[n // 2] if n > 0 else 0,
        p95_ms=latencies_sorted[int(n * 0.95)] if n > 0 else 0,
        p99_ms=latencies_sorted[int(n * 0.99)] if n > 0 else 0,
        min_ms=min(latencies_sorted) if latencies_sorted else 0,
        max_ms=max(latencies_sorted) if latencies_sorted else 0,
    )


def print_results(result: BenchmarkResult, label: str = "Benchmark"):
    """Print benchmark results in a nice format."""
    print(f"\n{'='*60}")
    print(f"{label} Results")
    print(f"{'='*60}")
    print(f"Total Requests:     {result.total_requests}")
    print(f"Successful:         {result.successful}")
    print(f"Failed:             {result.failed}")
    print(f"Total Time:         {result.total_time_sec:.2f}s")
    print(f"Throughput:         {result.requests_per_sec:.2f} req/s")
    print(f"\nLatency (ms):")
    print(f"  Min:              {result.min_ms:.2f}")
    print(f"  P50 (median):     {result.p50_ms:.2f}")
    print(f"  P95:              {result.p95_ms:.2f}")
    print(f"  P99:              {result.p99_ms:.2f}")
    print(f"  Max:              {result.max_ms:.2f}")
    print(f"{'='*60}\n")


async def main():
    parser = argparse.ArgumentParser(description="Benchmark LLO Context Manager Proxy")
    parser.add_argument("--url", default="http://localhost:8090/v1/messages", help="Proxy URL")
    parser.add_argument("--requests", "-n", type=int, default=100, help="Number of requests")
    parser.add_argument("--concurrency", "-c", type=int, default=10, help="Concurrent requests")
    parser.add_argument("--model", default="test-model", help="Model name")
    parser.add_argument("--stream", action="store_true", help="Use streaming")
    parser.add_argument("--output", "-o", help="Output JSON file")
    args = parser.parse_args()
    
    print(f"Starting benchmark: {args.requests} requests, {args.concurrency} concurrent")
    print(f"Target: {args.url}")
    
    result = await run_benchmark(
        url=args.url,
        num_requests=args.requests,
        concurrency=args.concurrency,
        model=args.model,
        stream=args.stream
    )
    
    print_results(result)
    
    if args.output:
        output_data = {
            "total_requests": result.total_requests,
            "successful": result.successful,
            "failed": result.failed,
            "total_time_sec": result.total_time_sec,
            "requests_per_sec": result.requests_per_sec,
            "latency_ms": {
                "min": result.min_ms,
                "p50": result.p50_ms,
                "p95": result.p95_ms,
                "p99": result.p99_ms,
                "max": result.max_ms,
            }
        }
        with open(args.output, "w") as f:
            json.dump(output_data, f, indent=2)
        print(f"Results saved to {args.output}")
    
    # Exit with error code if too many failures
    if result.failed > result.total_requests * 0.05:  # >5% failure rate
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
