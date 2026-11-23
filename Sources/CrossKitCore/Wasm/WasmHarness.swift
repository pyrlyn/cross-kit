import Foundation

/// A small Node.js program that loads a WebAssembly module with stub imports and calls its exports.
/// CrossKit uses it to run exported `test*` functions (one fresh instance per test), to read the coverage
/// counters of an instrumented module, to run an entry export and to debug WebAssembly in the Node inspector.
///
/// Usage: `node harness.mjs <module.wasm> test <export>…` | `run <export> [args…]` | `debug <export> [args…]`.
/// Test results are printed as `CROSSKIT_WASM {json}` lines.
public enum WasmHarness {
    public static let marker = "CROSSKIT_WASM "

    public static let source = #"""
    // CrossKit WebAssembly harness (generated; safe to delete).
    import { readFileSync } from "node:fs";

    const [wasmPath, mode = "test", ...rest] = process.argv.slice(2);
    const module = new WebAssembly.Module(readFileSync(wasmPath));
    const marker = "CROSSKIT_WASM ";

    function stubImports() {
      const imports = {};
      for (const imp of WebAssembly.Module.imports(module)) {
        const ns = (imports[imp.module] ??= {});
        switch (imp.kind) {
          case "function":
            ns[imp.name] = (...args) => { console.log(`${imp.module}.${imp.name}(${args.join(", ")})`); return 0; };
            break;
          case "memory": ns[imp.name] = new WebAssembly.Memory({ initial: 1 }); break;
          case "table": ns[imp.name] = new WebAssembly.Table({ initial: 0, element: "anyfunc" }); break;
          case "global": ns[imp.name] = new WebAssembly.Global({ value: "i32", mutable: false }, 0); break;
        }
      }
      return imports;
    }

    function instantiate() { return new WebAssembly.Instance(module, stubImports()); }

    function parseArg(text) {
      if (/^-?\d+$/.test(text)) {
        const n = BigInt(text);
        return n >= -(2n ** 31n) && n < 2n ** 32n ? Number(n) : n;
      }
      return Number(text);
    }

    const coverage = {};
    function collectCoverage(instance) {
      for (const [name, value] of Object.entries(instance.exports)) {
        if (name.startsWith("__ck_") && value instanceof WebAssembly.Global) {
          coverage[name] = (coverage[name] ?? 0) + Number(value.value);
        }
      }
    }

    if (mode === "test") {
      let failed = 0;
      for (const name of rest) {
        const started = performance.now();
        const result = { name, status: "passed" };
        let instance;
        try {
          instance = instantiate();
          const fn = instance.exports[name];
          if (typeof fn !== "function") throw new Error(`no exported function "${name}"`);
          const value = fn();
          if (value === 0 || value === 0n || value === false) {
            throw new Error(`returned ${value}`);
          }
        } catch (error) {
          result.status = "failed";
          result.message = String(error?.message ?? error);
          result.stack = String(error?.stack ?? "");
          failed++;
        }
        if (instance) collectCoverage(instance);
        result.duration = (performance.now() - started) / 1000;
        console.log(marker + JSON.stringify(result));
      }
      if (Object.keys(coverage).length) console.log(marker + JSON.stringify({ coverage }));
      process.exitCode = failed ? 1 : 0;
    } else {
      const instance = instantiate();
      const exported = Object.entries(instance.exports).filter(([, v]) => typeof v === "function");
      const name = rest[0] && rest[0] !== "-" ? rest[0]
        : (exported.find(([n]) => ["_start", "main", "run"].includes(n)) ?? exported.find(([, f]) => f.length === 0) ?? [])[0];
      const fn = name && instance.exports[name];
      if (typeof fn !== "function") {
        console.error(`No exported function to run${name ? ` named "${name}"` : ""}. Exports: ${exported.map(([n]) => n).join(", ") || "none"}`);
        process.exit(2);
      }
      const args = rest.slice(1).map(parseArg);
      if (mode === "debug") {
        // Paused here when a debugger is attached: breakpoints in wasm functions can now be set.
        debugger;
      }
      const value = fn(...args);
      if (value !== undefined) console.log(`${name}(${args.join(", ")}) = ${value}`);
      collectCoverage(instance);
      if (Object.keys(coverage).length) console.log(marker + JSON.stringify({ coverage }));
    }
    """#

    /// Writes the harness under the work directory and returns its path.
    public static func install(in workDirectory: URL) throws -> URL {
        let dir = workDirectory.appendingPathComponent("wasm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("crosskit-harness.mjs")
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != source { try source.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    public struct Output: Equatable, Sendable {
        public var results: [TestCaseResult] = []
        public var counters: [String: Int] = [:]
    }

    public static func parse(_ output: String) -> Output {
        var parsed = Output()
        for line in output.components(separatedBy: "\n") {
            guard let range = line.range(of: marker) else { continue }
            let json = Data(line[range.upperBound...].utf8)
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: json) else { continue }
            if case .object(let counters)? = value["coverage"] {
                for (name, count) in counters { parsed.counters[name] = Int(count.doubleValue ?? 0) }
                continue
            }
            guard let name = value["name"]?.stringValue else { continue }
            let status: TestStatus = value["status"]?.stringValue == "passed" ? .passed : .failed
            var message = value["message"]?.stringValue
            if let stack = value["stack"]?.stringValue, !stack.isEmpty { message = stack }
            parsed.results.append(TestCaseResult(name: name, status: status, duration: value["duration"]?.doubleValue,
                                                 output: status == .failed ? message : nil))
        }
        return parsed
    }
}
