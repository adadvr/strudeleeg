# Tareas — Demo A/B macOS: Strudel vs Mini Engine

Plan derivado de [devstrudeleeg.md](../devstrudeleeg.md). Marcar con `[x]` al completar. Borrar este archivo cuando todo esté terminado.

## Setup
- [x] Inicializar repo git en branch `main` y vincular remote `https://github.com/adadvr/strudeleeg.git`
- [x] Primer commit (brief + tareas + .gitignore)
- [x] Push inicial a origin

## F0 — Scaffold
- [x] Estructura Swift Package (app SwiftUI ejecutable, target `NativeEngine` aislado)
- [x] Ventana con dos paneles vacíos (izq: Strudel, der: Mini Engine)
- [x] Generar samples `pad.wav` y `bell.wav` (set libre, aptos para meditación)
- [x] "Hola mundo" de audio: un WAV suena por AVAudioEngine
- [x] Script de build que arma `DemoStrudel.app`
- [x] Commit F0

## F1 — Motor B seco
- [x] `MiniNotationParser`: subset `stack`, `s`, `note`, `slow`, `fast`, `<...>`, secuencia, `[...]`, `gain`, `room`, `cutoff` (clean-room, solo doc pública)
- [x] `Scheduler` sobre AVAudioEngine tocando el código semilla sin efectos
- [x] Validar timing/secuencia contra Strudel de referencia (ValidateEvents: 11/11 OK)
- [x] Aviso amable si hay función fuera del subset (no crashear)
- [x] Commit F1

## F2 — Motor B efectos
- [x] `cutoff` → AVAudioUnitEQ low-pass
- [x] `room` → AVAudioUnitReverb (wet, preset mediumHall)
- [x] `gain` → volumen del nodo
- [ ] Verificar piso de aceptación: código semilla suena igual en ambos lados (pendiente de F3 para comparar A/B de oído)
- [x] Commit F2

## F3 — Motor A (Strudel WebView)
- [x] `index.html` local con `@strudel/web` bundleado (offline, esbuild iife 1.2MB)
- [x] `StrudelWebEngine` con `evaluateJavaScript` desde el editor izquierdo
- [x] Registrar samples con `samples({ bell: { c4: [...] } }, baseUrl)` — mismos WAV, afinación C4 alineada con Motor B
- [x] Resolver acceso a archivos locales (`loadFileURL(_:allowingReadAccessTo: Bundle.module.resourceURL)`)
- [x] Commit F3

## F4 — UI + empaque
- [ ] UI final: labels, Play por lado, Stop compartido, mismo código semilla en ambos editores
- [ ] Build Release → `DemoStrudel.app` autocontenido (samples + Strudel dentro)
- [ ] Verificar firma/permisos (cert "moonshot" según Adad) o instrucciones Gatekeeper
- [ ] Empaquetar `.dmg`
- [ ] `README.md` para el jefe (cómo abrir, qué compara, nota de expectativas)
- [ ] Commit F4 + push final
