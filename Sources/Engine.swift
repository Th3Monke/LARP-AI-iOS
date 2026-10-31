import Foundation
import llama

enum EngineError: LocalizedError {
    case load(String), context, tooLong, decode
    var errorDescription: String? {
        switch self {
        case .load(let name): return "Couldn't load \(name). It may be too big for this iPhone's memory. Try a smaller model."
        case .context: return "Couldn't start the model. Try a smaller model or a shorter chat memory in Settings."
        case .tooLong: return "This chat is longer than the model's memory. Start a new chat."
        case .decode: return "The model stopped unexpectedly. Try again."
        }
    }
}

/// Set from any thread to stop the current answer.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

/// llama.cpp running fully on the device (Metal GPU).
actor LlamaEngine {
    static let shared = LlamaEngine()
    nonisolated let stop = StopFlag()

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var nCtx: Int = 4096
    private(set) var loadedPath: String?

    init() { llama_backend_init() }

    func load(path: String, contextSize: Int) throws {
        if loadedPath == path && ctx != nil && nCtx == contextSize { return }
        unload()
        var mp = llama_model_default_params()
        #if targetEnvironment(simulator)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = 99
        #endif
        guard let m = llama_model_load_from_file(path, mp) else {
            throw EngineError.load((path as NSString).lastPathComponent)
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextSize)
        cp.n_batch = 512
        let threads = Int32(max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw EngineError.context
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        nCtx = contextSize
        loadedPath = path
    }

    func unload() {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil; model = nil; vocab = nil; loadedPath = nil
    }

    /// Streams the reply for `messages` (role, content), calling `onText` with each new piece.
    func generate(messages: [(String, String)], temperature: Float, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) throws {
        guard let ctx, let vocab else { throw EngineError.context }
        stop.value = false
        let prompt = applyTemplate(messages)
        llama_memory_clear(llama_get_memory(ctx), true)
        var tokens = tokenize(prompt)
        if tokens.isEmpty { throw EngineError.decode }
        if tokens.count >= nCtx - 64 { throw EngineError.tooLong }

        // read the prompt in chunks
        var i = 0
        while i < tokens.count {
            let n = min(512, tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress! + i, Int32(n)))
            }
            if rc != 0 { throw EngineError.decode }
            i += n
            if stop.value { return }
        }

        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        var pending: [UInt8] = []
        var produced = 0
        var pos = tokens.count
        while produced < maxTokens && pos < nCtx - 1 && !stop.value {
            var tok = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            pending += piece(tok)
            let text = takeValidUTF8(&pending)
            if !text.isEmpty { onText(text) }
            if llama_decode(ctx, llama_batch_get_one(&tok, 1)) != 0 { break }
            produced += 1
            pos += 1
        }
        if !pending.isEmpty { onText(String(decoding: pending, as: UTF8.self)) }
    }

    // MARK: - helpers

    private func applyTemplate(_ msgs: [(String, String)]) -> String {
        let tmpl = llama_model_chat_template(model, nil)
        let roles = msgs.map { strdup($0.0) }
        let contents = msgs.map { strdup($0.1) }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var chat = (0..<msgs.count).map { llama_chat_message(role: UnsafePointer(roles[$0]), content: UnsafePointer(contents[$0])) }
        var size = Int32(msgs.reduce(0) { $0 + $1.1.utf8.count } * 2 + 1024)
        var buf = [CChar](repeating: 0, count: Int(size))
        var n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, size)
        if n > size {
            size = n + 1
            buf = [CChar](repeating: 0, count: Int(size))
            n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, size)
        }
        if n < 0 {   // unknown template: plain fallback
            return msgs.map { "\($0.0): \($0.1)\n" }.joined() + "assistant:"
        }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let count = text.utf8.count
        var tokens = [llama_token](repeating: 0, count: count + 16)
        var n = llama_tokenize(vocab, text, Int32(count), &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(count), &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(0, n))))
    }

    private func piece(_ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, 64, 0, true)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, t, &buf, -n, 0, true)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    /// Returns the longest complete UTF-8 prefix (emoji etc. can span several tokens).
    private func takeValidUTF8(_ bytes: inout [UInt8]) -> String {
        var end = bytes.count
        while end > 0 && bytes.count - end <= 4 {
            if let s = String(bytes: bytes[0..<end], encoding: .utf8) {
                bytes.removeFirst(end)
                return s
            }
            end -= 1
        }
        if bytes.count > 16 {   // broken sequence: give up on it
            let s = String(decoding: bytes, as: UTF8.self)
            bytes.removeAll()
            return s
        }
        return ""
    }
}
