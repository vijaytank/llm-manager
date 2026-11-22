# Context Manager Proxy Benchmarks

## Running Benchmarks

### Prerequisites
- Python 3.10+
- `httpx` package (already in requirements.txt)
- Proxy server running on target URL

### Basic Usage

```bash
# Run 100 requests with 10 concurrent connections
python benchmark_proxy.py --url http://localhost:8090/v1/messages --requests 100 --concurrency 10

# Run with custom model and save results
python benchmark_proxy.py --url http://localhost:8090/v1/messages -n 500 -c 20 --model my-model -o results.json
```

### Options

| Option | Short | Default | Description |
|--------|-------|---------|-------------|
| `--url` | | `http://localhost:8090/v1/messages` | Proxy endpoint URL |
| `--requests` | `-n` | `100` | Total number of requests |
| `--concurrency` | `-c` | `10` | Concurrent connections |
| `--model` | | `test-model` | Model name to use |
| `--stream` | | `false` | Use streaming mode |
| `--output` | `-o` | | Save results to JSON file |

### CI Integration

Add to `.github/workflows/ci.yml`:

```yaml
benchmark:
  name: Performance Benchmark
  runs-on: ubuntu-latest
  needs: python-context-manager
  if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
  steps:
    - uses: actions/checkout@v4
    - name: Start proxy
      run: |
        cd llo-core/context_manager
        python -m uvicorn proxy:app --host 0.0.0.0 --port 8090 &
        sleep 3
    - name: Run benchmark
      run: |
        python benchmarks/benchmark_proxy.py -n 200 -c 20 -o bench-results.json
    - name: Upload results
      uses: actions/upload-artifact@v4
      with:
        name: benchmark-results
        path: llo-core/context_manager/bench-results.json
```

### Interpreting Results

- **P50 (median)**: Typical request latency
- **P95**: 95% of requests faster than this (tail latency)
- **P99**: 99% of requests faster than this (extreme tail)
- **Throughput**: Requests per second (higher is better)

### Targets

| Metric | Target |
|--------|--------|
| P50 latency | < 50ms |
| P95 latency | < 200ms |
| P99 latency | < 500ms |
| Throughput | > 100 req/s (10 concurrent) |
| Error rate | < 1% |

### Compression Overhead Test

To measure compression overhead, run with a large conversation:

```bash
# Create a test with large payload to trigger compression
python benchmarks/benchmark_compression.py
```

(Script to be added)
