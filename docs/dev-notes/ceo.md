# 🔱 CEO MASTERPLAN (Apex Lite)
## [STRICT ORDERS & VISION]

---

## ✅ PHASE 3 & 3.5 COMPLETE

| Milestone | Status | Details |
|:---|---:|---|
| Phase 3 Core (Self-Healing, Security, UI, Tests) | ✅ | All L7-L10 tests pass |
| Phase 3.5 Model Picker | ✅ | Local file loading + premium UI |
| IP Leak Audit | ✅ | Zero SaaS references confirmed |

## 🎯 NEXT — PHASE 4.1: FLUTTER_GEMMA V0.14.5+ & VISION AI

Phase 4.1 focuses on integrating the official `flutter_gemma` v0.14.5+ package for Gemma 4 support, adding Vision capabilities, and finalizing submission:
1. **Upgrade Inference Engine** — Use `flutter_gemma` v0.14.5+. Do NOT build custom Kotlin MethodChannels. Rely on the package's built-in LiteRT-LM and FFI capabilities.
2. **Vision & State Management** — Implement Variable Image Resolution (Visual Token Budget) and migrate to Riverpod 3.0 `AsyncNotifier`.
3. **Demo Video** — 3 minutes. Wi-Fi OFF. Follow `demo_script.md`.
4. **Submit** — Kaggle/Devpost. Remove `apex_local_supreme_backup/` from submission.

## 🔱 [STRICT ORDERS — PHASE 4.1]
1. **Agent (Dart Dev):** Upgrade `flutter_gemma`, implement `.litertlm` model loading, and add Vision support via `Uint8List`. **Check Omega Impact Matrix for Riverpod State** — implement `ref.onDispose` to prevent zombie streams!
2. **Agent (Dart Dev):** Ensure Native Function Calling `<|tool_call>` is correctly routed through `FunctionCallParser`.
3. **Agent (Video):** Record 3-min demo. Use screen recorder. Wi-Fi OFF icon visible. Follow demo_script.md beats.
4. **Agent (Submit):** Package code. Verify IP leak one final time.

---

## 🛑 OMEGA IMPACT HINTS (Standing)
- "Before adding any model loading logic → Check Omega Impact Matrix for **LocalInference**"
- "Before changing recovery prompts → Check Omega Impact Matrix for **AetherCore**"
- "Before submission → Check Omega Impact Matrix for **excluded features** list"

---
*CEO Apex Lite — Phase 3.5 Complete. Awaiting Phase 4 execution.*