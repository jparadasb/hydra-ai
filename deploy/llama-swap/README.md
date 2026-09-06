# Local GPU worker model profiles

These profiles are for the two Proxmox GPU workers:

- CT209 / Tesla M40: Qwen2.5-Coder-14B-Instruct Q4_K_M. Text and tool-planning model.
- CT206 / RTX 3060: Qwen2.5-VL-7B-Instruct Q4_K_M plus its Q8 projector. Screenshot and image-verification model.

Both profiles expose an OpenAI-compatible API through `llama-swap` on port `9090`. The model server binds to loopback; Hydra worker is the external coordinator-facing process.

The model files live under `/opt/models`, which is backed by the `StorageOne` SSD on both containers. Keep `CUDA_VISIBLE_DEVICES=0`: each LXC exposes only its assigned GPU as `/dev/nvidia0` inside the container.

## Files

- `ct209-m40.yaml`: text/tool model profile.
- `ct206-rtx3060.yaml`: multimodal model profile.

The `llama.cpp` build must include the model architecture and multimodal (`mtmd`) support. Validate with the smoke-test commands below after installing the model files.

```sh
curl http://127.0.0.1:9090/v1/models
curl http://127.0.0.1:9090/health
```

For vision requests, send an OpenAI-compatible `content` array containing `text` and an `image_url` data URL. Use Playwright for browser actions and treat model output as a proposed action; keep assertions in the test runner.
