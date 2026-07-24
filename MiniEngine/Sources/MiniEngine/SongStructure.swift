// ---------------------------------------------------------------------------
// SongStructure.swift — Estructura de canción (P2) para MiniEngine
//
// Combinadores implementados:
//   pick(idxPat, pats)         — selecciona patrón por índice; corre en tiempo ABSOLUTO (no reinicia)
//   pickOut(idxPat, pats)      — alias de pick (semántica idéntica: innerJoin, no reinicia)
//   pickRestart(idxPat, pats)  — selecciona patrón por índice; REINICIA el patrón en el onset del slot
//   indexPattern(mini)         — convierte mini-notación string a Pattern<Int>
//   Pattern.layer([f1,f2,...]) — aplica transformaciones en paralelo y apila (stack)
//
// Semántica (doc v1.3):
//   - pick / pickOut: innerJoin — el patrón elegido corre en tiempo absoluto sin
//     reiniciarse. El tiempo del ciclo global fluye libremente a través del patrón seleccionado.
//   - pickRestart: el onset del hap de índice actúa como "tiempo cero" para el
//     sub-patrón, que se reinicia en cada nuevo slot de índice.
//   - layer: stack de transformaciones sobre sí mismo — self.layer([f1,f2]) == stack([f1(self),f2(self)])
//
// CLEAN-ROOM: implementado desde docs públicas strudel.cc/learn (no se leyó el JS).
// ---------------------------------------------------------------------------

// MARK: - pick / pickOut

/// Selecciona qué patrón suena según un índice patroneado.
/// El patrón elegido corre en tiempo ABSOLUTO (no se reinicia) — innerJoin.
/// El índice se evalúa por su estructura temporal; dentro de cada hap del índice
/// se consulta el sub-patrón correspondiente sobre la misma porción temporal (ih.part).
///
/// Desbordamiento de índice: wrap modular (índice negativo también se maneja).
public func pick<T>(_ idx: Pattern<Int>, _ pats: [Pattern<T>]) -> Pattern<T> {
    guard !pats.isEmpty else { return .silence }
    return Pattern { span in
        idx.query(span).flatMap { ih -> [Hap<T>] in
            let raw = ih.value
            // Wrap modular para índices fuera de rango (incluyendo negativos)
            let i = ((raw % pats.count) + pats.count) % pats.count
            // Consultar el sub-patrón en el span del slot del índice (tiempo absoluto)
            return pats[i].query(ih.part).compactMap { oh in
                // Intersección del span del sub-patrón con el slot del índice
                guard let part = oh.part.intersection(ih.part) else { return nil }
                return Hap(whole: oh.whole, part: part, value: oh.value)
            }
        }
    }
}

/// Alias de pick — semántica idéntica (innerJoin, no reinicia).
/// El nombre "pickOut" proviene del API público de Strudel.
public func pickOut<T>(_ idx: Pattern<Int>, _ pats: [Pattern<T>]) -> Pattern<T> {
    pick(idx, pats)
}

// MARK: - pickRestart

/// Selecciona qué patrón suena según un índice patroneado, REINICIANDO el sub-patrón
/// en el onset de cada slot del índice.
///
/// A diferencia de pick (tiempo absoluto), pickRestart usa el comienzo del slot
/// (ih.wholeOrPart.begin) como "tiempo cero" para el sub-patrón elegido.
/// Esto produce una alineación desde el inicio de cada sección, sin importar
/// en qué punto del tiempo global se encuentra el patrón interno.
public func pickRestart<T>(_ idx: Pattern<Int>, _ pats: [Pattern<T>]) -> Pattern<T> {
    guard !pats.isEmpty else { return .silence }
    return Pattern { span in
        idx.query(span).flatMap { ih -> [Hap<T>] in
            let raw = ih.value
            let i = ((raw % pats.count) + pats.count) % pats.count
            // t0 = onset del slot del índice (desde wholeOrPart para correcta alineación)
            let t0 = ih.wholeOrPart.begin
            // Desplazar el span de consulta al espacio temporal del sub-patrón (restando t0)
            let inner = TimeSpan(ih.part.begin - t0, ih.part.end - t0)
            // Consultar el sub-patrón en coordenadas locales (relativas a t0)
            return pats[i].query(inner).compactMap { oh in
                // Volver al tiempo absoluto (sumando t0)
                let backPart = TimeSpan(oh.part.begin + t0, oh.part.end + t0)
                let backWhole = oh.whole.map { TimeSpan($0.begin + t0, $0.end + t0) }
                // Clipear al slot del índice
                guard let clipped = backPart.intersection(ih.part) else { return nil }
                return Hap(whole: backWhole, part: clipped, value: oh.value)
            }
        }
    }
}

// MARK: - indexPattern

/// Convierte una mini-notación string a Pattern<Int>.
/// Valores no numéricos se mapean a 0.
/// Ejemplo: indexPattern("<0 1 2>") alterna entre índices 0, 1, 2 ciclo a ciclo.
public func indexPattern(_ mini: String) -> Pattern<Int> {
    MiniNotationCore.parse(mini).map { str in
        Int(str) ?? 0
    }
}

// MARK: - Pattern.layer

extension Pattern {
    /// Aplica varias transformaciones en paralelo sobre sí mismo y apila los resultados.
    ///
    /// self.layer([f1, f2, f3]) == stack([f1(self), f2(self), f3(self)])
    ///
    /// Útil para construir texturas donde la misma fuente se escucha en múltiples
    /// variantes simultáneamente (velocidad, efectos, transposición, etc.).
    public func layer(_ fs: [(Pattern<T>) -> Pattern<T>]) -> Pattern<T> {
        stack(fs.map { $0(self) })
    }
}
