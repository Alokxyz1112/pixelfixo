# Model credits

| File | Model | Author | License | Changes |
|---|---|---|---|---|
| realesr-general-x4v3-d40.onnx, realesr-general-x4v3-d30.onnx | Real-ESRGAN realesr-general-x4v3 and realesr-general-wdn-x4v3 | Xintao Wang et al., https://github.com/xinntao/Real-ESRGAN (release v0.2.5.0) | BSD 3-Clause | The two official weight sets are mixed per parameter (40/60 and 30/70, the same mix Real-ESRGAN uses for its denoise strength option) and written as ONNX (opset 17, fp32). |
| 4xNomosWebPhoto_RealPLKSR.onnx | 4xNomosWebPhoto_RealPLKSR | Philip Hofmann (Phhofm, helaman), https://github.com/Phhofm/models/releases/tag/4xNomosWebPhoto_RealPLKSR | CC BY 4.0 | Converted from the official .pth to ONNX (opset 17, fp32). Weights unchanged. |
| RealESRGAN_x4plus_anime_6B.onnx | Real-ESRGAN x4plus anime 6B | Xintao Wang et al., https://github.com/xinntao/Real-ESRGAN | BSD 3-Clause | Converted to ONNX. Weights unchanged. |

CC BY 4.0 text: LICENSE-CC-BY-4.0.txt. BSD text: LICENSE-Real-ESRGAN.txt.
