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
- [ ] `MiniNotationParser`: subset `stack`, `s`, `note`, `slow`, `fast`, `<...>`, secuencia, `[...]`, `gain`, `room`, `cutoff` (clean-room, solo doc pública)
- [ ] `Scheduler` sobre AVAudioEngine tocando el código semilla sin efectos
- [ ] Validar timing/secuencia contra Strudel de referencia
- [ ] Aviso amable si hay función fuera del subset (no crashear)
- [ ] Commit F1

## F2 — Motor B efectos
- [ ] `cutoff` → AVAudioUnitEQ low-pass
- [ ] `room` → AVAudioUnitReverb (wet)
- [ ] `gain` → volumen del nodo
- [ ] Verificar piso de aceptación: código semilla suena igual en ambos lados
- [ ] Commit F2

## F3 — Motor A (Strudel WebView)
- [ ] `index.html` local con `@strudel/web` bundleado (offline)
- [ ] `StrudelWebEngine` con `evaluateJavaScript` desde el editor izquierdo
- [ ] Registrar samples con `samples({...}, baseUrl)` — mismos WAV
- [ ] Resolver acceso a archivos locales (`loadFileURL(_:allowingReadAccessTo:)`)
- [ ] Commit F3

## F4 — UI + empaque
- [ ] UI final: labels, Play por lado, Stop compartido, mismo código semilla en ambos editores
- [ ] Build Release → `DemoStrudel.app` autocontenido (samples + Strudel dentro)
- [ ] Verificar firma/permisos (cert "moonshot" según Adad) o instrucciones Gatekeeper
- [ ] Empaquetar `.dmg`
- [ ] `README.md` para el jefe (cómo abrir, qué compara, nota de expectativas)
- [ ] Commit F4 + push final
