# Third party

## Models

| File | Author | License | Notes |
|---|---|---|---|
| 4xLSDIRCompactC.onnx | Philip Hofmann (Phhofm), https://github.com/Phhofm/models | CC BY 4.0 | Converted from the official .pth to ONNX. Weights unchanged. |
| 4xNomosWebPhoto_RealPLKSR.onnx | Philip Hofmann (Phhofm), https://github.com/Phhofm/models | CC BY 4.0 | Converted from the official .pth to ONNX. Weights unchanged. |
| realesr-general-x4v3-d50.onnx, realesr-general-x4v3-d30.onnx | Xintao Wang et al., https://github.com/xinntao/Real-ESRGAN | BSD 3-Clause | The official realesr-general-x4v3 and wdn-x4v3 weights mixed per parameter (50/50 and 30/70) and converted to ONNX. |
| RealESRGAN_x4plus_anime_6B.onnx | Xintao Wang et al., https://github.com/xinntao/Real-ESRGAN | BSD 3-Clause | Converted to ONNX. Weights unchanged. |

Full texts: [assets/models/LICENSE-CC-BY-4.0.txt](assets/models/LICENSE-CC-BY-4.0.txt) and [assets/models/LICENSE-Real-ESRGAN.txt](assets/models/LICENSE-Real-ESRGAN.txt).

## Libraries

- ONNX Runtime (Microsoft), MIT. Used through onnxruntime-android and flutter_onnxruntime.
- Flutter and the Dart packages listed in pubspec.yaml, each under its own license (shown in the app under About, Licenses).
- Inter and Space Grotesk fonts, SIL Open Font License 1.1 (assets/fonts).

## README sample photo

Earthrise, Apollo 8, NASA (public domain). Downscaled to 220 px for the before image.
