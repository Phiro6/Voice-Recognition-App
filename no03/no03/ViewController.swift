import Cocoa
import AVFoundation // マイク入力や音声データ処理（Audio Engine、フォーマット変換）を担う標準フレームワーク
import WhisperKit   // デバイス内で動作するOpenAIの高性能音声認識AI「Whisper」を扱うライブラリ

/// macOSの画面（View）を制御するクラス。
/// NSViewControllerを継承し、画面上のボタンやテキストエリアの挙動を管理する。
class ViewController: NSViewController {
    
    // MARK: - UI部品 (Outlets)
    // 画面上のUI要素とコードを結びつけるための変数（@IBOutlet）。
    // NSTextView（複数行のテキスト領域）やNSButton（ボタン）を保持。
    @IBOutlet var inputTextView: NSTextView!
    @IBOutlet var outputTextView: NSTextView!
    @IBOutlet weak var recordButton: NSButton!
    
    // MARK: - 音声処理・AI制御用のプロパティ（メンバ変数）
    
    /// 音声の入力・処理・出力をノード（部品）の結合で管理するシステム
    let audioEngine = AVAudioEngine()
    
    /// 変換した音声の波形データ（PCM 32bit float形式）を一時的に保存しておくための動的配列
    var audioData: [Float] = []
    
    /// WhisperKitのインスタンス。オプショナル型（?）で初期状態は空（nil）
    var whisper: WhisperKit?
    
    /// 録音中かどうかを追跡するブール型のフラグ（初期値は偽）
    var isRecording = false
    
    // MARK: - ライフサイクルメソッド
    
    /// 画面（View）がメモリに読み込まれた直後に1度だけ自動で呼び出されるメソッド
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Whisperの起動準備が整うまでボタンを押せないように初期化
        recordButton.isEnabled = false
        recordButton.title = "準備中..."
        
        // 【重要】アプリ起動時にマイク入力ノードにアクセスし、ハードウェアとの接続を早期に確立。
        // これをしないと、初回録音時に接続ラグによる音声の途切れやエラーが発生する。
        // `_ =` は返り値を使用しない（破棄する）ことを明示する文法。
        _ = audioEngine.inputNode
        
        // Whisperモデルをバックグラウンドでロードする自作メソッドを呼び出し
        setupWhisper()
    }
    
    // MARK: - 録音コントロール
    
    /// 録音ボタンがクリックされたときに呼び出されるアクションメソッド（@IBAction）
    /// - Parameter sender: クリックされたボタン自身（NSButton型）
    @IBAction func didTapRecordButton(_ sender: NSButton) {
        if isRecording {
            // 現在録音中なら停止処理へ
            isRecording = false
            sender.title = "録音開始"
            stopRecording()
        } else {
            // 録音を開始する前のUI更新
            inputTextView.string = "録音中..."
            outputTextView.string = "ここに生成されたAppleScriptが表示されます"
            
            // 連続タップによるバグを防ぐため、一時的にボタンを無効化
            sender.isEnabled = false
            
            // 【苦労・工夫ポイント】UIの書き換え（「録音中...」への変更）を画面に確実に反映させるため、
            // メインスレッド（DispatchQueue.main）のキューに0.1秒の遅延（asyncAfter）を挟んで録音を開始する。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // 録音処理を開始し、成否を定数successに格納
                let success = self.startRecording()
                if success {
                    self.isRecording = true
                    sender.title = "停止"
                } else {
                    self.isRecording = false
                    sender.title = "録音開始"
                    self.inputTextView.string = "録音エラーが発生しました"
                }
                // 処理が終わったのでボタンを再度有効化
                sender.isEnabled = true
            }
        }
    }
    
    /// マイク入力を開始し、Whisperが求める音声形式にリアルタイム変換して保存するメソッド
    /// - Returns: 起動に成功すれば true、失敗すれば false
    func startRecording() -> Bool {
        print("--- 録音プロセス開始 ---")
        
        // 新しい録音を行うため、配列に残っている前回の音声波形データをすべて削除
        audioData.removeAll()
        
        // マイクの入力ノード（音を取り込む窓口）を取得
        let inputNode = audioEngine.inputNode
        
        // 現在のマイクの音声フォーマット（例: 44.1kHz または 48kHz / ステレオなど、環境依存）を取得
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        // 【超重要 / 苦労した仕様】Whisperモデルが要求する「16kHz / モノラル / 32bit浮動小数点(PCM)」のフォーマットを厳格に定義。
        // guard文を用いて、フォーマットの作成に失敗した場合は即座にfalseを返し関数を抜ける（安全対策）。
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return false }
        
        // 元のフォーマット（inputFormat）から標的のフォーマット（targetFormat）へ変換するコンバータを作成
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("変換器の作成に失敗")
            return false
        }
        
        // 【クラッシュ防止の工夫】古いタップ（音声の監視追跡）が残っているとクラッシュするため、一度確実に削除。
        inputNode.removeTap(onBus: 0)
        
        // マイク入力に「Tap（盗聴器のようなもの）」を設置し、一定周期（bufferSize）ごとに音声をブロック単位でキャッチする。
        // クロージャ（[weak self]）を使い、循環参照によるメモリリークを防ぐ。
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return } // selfが既に破棄されていたら何もしない（安全対策）
            
            // ── ここからリアルタイム音声フォーマット変換処理 ──
            
            // サンプリングレートの比率（例: 16000 / 44100）を計算し、変換後に必要となるバッファサイズを算出
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            
            // 変換後の音声データを格納するための空のPCMバッファを作成
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
            
            // コンバータにデータを供給するためのインブロック（クロージャ）。
            // 1度の変換要求に対して1度だけ元のバッファ（buffer）を渡し、2回目は「データなし（.noDataNow）」を返す制御。
            var isUsed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if isUsed { outStatus.pointee = .noDataNow; return nil }
                isUsed = true
                outStatus.pointee = .haveData
                return buffer // 元の音声データをコンバータに提供
            }
            
            // 実際に変換処理を実行。結果は convertedBuffer に書き込まれる
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            
            // 変換されたPCMバッファから、32bit Float型の生データ（ポインタ）を取り出す
            if let channelData = convertedBuffer.floatChannelData?[0] {
                // UnsafeBufferPointerを使って安全にSwiftの「[Float]配列」へとコピー・変換する
                let frames = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
                
                // クラスのメンバ変数 `audioData` に、新しく変換された波形フレームを末尾に追加（結合）していく
                self.audioData.append(contentsOf: frames)
            }
        }
        
        // 音声エンジン（Audio Engine）がまだ動いていない場合のみ起動処理を行う
        if !audioEngine.isRunning {
            do {
                audioEngine.prepare()     // リソースの事前確保
                try audioEngine.start()   // エンジンの開始（マイク入力の有効化）
            } catch {
                print("エンジン開始失敗: \(error)")
                return false
            }
        }
        
        return true
    }
    
    /// 録音を停止し、取り込んだ音声の認識フェーズへ移行するメソッド
    func stopRecording() {
        print("録音停止処理。データ数: \(audioData.count)")
        
        // 【最重要工夫ポイント】Audio Engine自体は停止させず、マイクの「Tap（監視）」だけを外す。
        // エンジンごと止めると、2回目に録音ボタンを押した際にハードウェアの再初期化が間に合わずエラーになる問題をこれで解決。
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // 最後の音声データが完全に配列に書き込まれるのを待つため、0.3秒だけ非同期で遅延させてからAI認識を実行
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.runWhisperRecognition()
        }
    }
    
    // MARK: - Whisper & AI 連携
    
    /// アプリ起動時に、バックグラウンド（非同期）でWhisperのAIモデルを読み込むメソッド
    func setupWhisper() {
        // Swiftの並行処理（Structured Concurrency）である `Task` を使用し、重い処理を非同期で実行
        Task {
            do {
                print("Whisperモデル読み込み中...")
                // `try await` を使い、モデルの初期化（数秒〜十数秒かかる重い処理）をバックグラウンドで待機。
                // これによりロード中もMacの画面がフリーズしない。
                let initializedWhisper = try await WhisperKit()
                
                // UIの書き換えは必ず「メインスレッド」で行うというiOS/macOSの鉄則に従い、戻す
                DispatchQueue.main.async {
                    self.whisper = initializedWhisper
                    self.recordButton.isEnabled = true // 準備ができたのでボタンを解禁
                    self.recordButton.title = "録音開始"
                }
            } catch {
                print("Whisper初期化失敗: \(error)")
            }
        }
    }
    
    /// 溜まった音声波形データ（audioData）を、Whisperを用いて日本語テキストに変換するメソッド
    func runWhisperRecognition() {
        // Whisperが初期化済み、かつ音声データが空ではないことを確認（安全のガード）
        guard let whisperInstance = whisper, !audioData.isEmpty else { return }
        
        Task {
            do {
                // 音声認識のオプションを設定（明示的に日本語を指定することで、認識精度と速度を向上）
                let options = DecodingOptions(language: "ja")
                
                // 配列（[Float]）を直接Whisperに放り込み、テキスト化を依頼（非同期待機）
                let results = try await whisperInstance.transcribe(audioArray: audioData, decodeOptions: options)
                
                // 認識結果の配列から、最初の候補（最も確率の高い文章）を取得
                if let recognizedText = results.first?.text {
                    print("認識結果: \(recognizedText)")
                    
                    // UI（inputTextView）に認識した文字をセットし、OllamaのAI処理へ渡す（メインスレッドで実行）
                    DispatchQueue.main.async {
                        self.inputTextView.string = recognizedText
                        self.processWithOllama(prompt: recognizedText)
                    }
                }
            } catch {
                print("認識エラー: \(error)")
            }
        }
    }
    
    /// 認識したテキストを、AIへの指示書（プロンプト）に整形するメソッド
    /// - Parameter prompt: ユーザーが声で喋った生のテキスト文字列
    func processWithOllama(prompt: String) {
        self.outputTextView.string = "AIがスクリプトを作成中..."
        
        // 【創意工夫ポイント】
        // 「launch」ではなく「activate」を使わせる指示文を追加します。
        let enhancedPrompt = """
        ユーザーの要望: 「\(prompt)」
        この要望を叶えるためのmacOS用AppleScriptを作成してください。
        
        【厳格な制約ルール】
        1. アプリを起動・操作する場合は、裏で起動するだけの「launch」は使わず、必ず画面の最前面に表示させるために「activate」コマンドを使用してください。
        例： tell application "Microsoft Excel" to activate
        
        2. 回答は ```applescript と ``` で囲んだコードブロックのみを出力してください。
        """
        
        askOllama(prompt: enhancedPrompt)
    }
    
    /// ローカルで稼働しているAIサーバー（Ollama）に対してHTTP POST通信を行うメソッド
    /// - Parameter prompt: 整形済みの指示テキスト
    func askOllama(prompt: String) {
        // ローカルPC（127.0.0.1）のポート11434で待ち受けているOllamaのAPIエンドポイントURLを設定
        let url = URL(string: "http://127.0.0.1:11434/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST" // データを送信するためPOSTメソッドを指定
        
        // AIに渡すパラメータを辞書（Dictionary）形式で定義
        let parameters: [String: Any] = [
            "model": "gemma4",    // 使用するLLMのモデル名（ローカルにインストールされているもの）
            "prompt": prompt,     // 指示内容
            "stream": false       // 逐次出力（ストリーミング）ではなく、全身が完成してから一括で受け取る設定
        ]
        
        // Swiftの辞書オブジェクトを、ネットワーク通信用の「JSONバイナリデータ」にシリアライズ（変換）してボディに格納
        request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
        
        // URLSessionのデータタスクを使用し、バックグラウンドでHTTPリクエストを送信
        URLSession.shared.dataTask(with: request) { data, _, _ in
            // 通信結果（data）が存在し、それがJSONとして解析でき、かつ中の "response" キーに文字列が入っているかを安全にチェック
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else { return }
            
            // 通信完了後のUI更新およびスクリプト実行はメインスレッドにディスパッチする
            DispatchQueue.main.async {
                // AIが返した生のテキスト（解説やコードブロックが含まれる）を画面に出力
                self.outputTextView.string = responseText
                
                // 【連携仕様】生テキストからAppleScriptのコードだけを正規表現で抜き出す
                if let script = self.extractAppleScript(from: responseText) {
                    // 抜き出しに成功したら、実際にMac上で実行させる
                    self.executeAppleScript(script)
                }
            }
        }.resume() // タスクを作成しただけでは動かないため、`.resume()` を呼んで通信を開始させる
    }

    // MARK: - AppleScript ユーティリティ
    
    /// AIの返答テキストから正規表現を用いてAppleScriptコードだけを抽出する関数
    /// - Parameter text: AIから返ってきた生のテキスト全体
    /// - Returns: 抽出されたコード文字列（見つからなければnil）
    func extractAppleScript(from text: String) -> String? {
        // 「```applescript\n（任意の文字列）\n```」に一致するパターンを定義
        // [\\s\\S]*? は、改行を含むあらゆる文字の「最短一致（一番近い閉じカッコまで）」を意味する
        let pattern = "```applescript\\n([\\s\\S]*?)\\n```"
        
        // 正規表現オブジェクトを作成（失敗時はnilを返す）
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        
        // 扱いやすくするため、SwiftのStringからObjective-CのNSStringにキャスト（文字数のカウント位置のズレを防ぐため）
        let nsString = text as NSString
        
        // テキスト全体（NSRange）を対象に検索を実行し、最初のマッチ結果を取得
        if let match = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length)).first {
            // `match.range(at: 1)` で、パターン内の最初のカッコ `([\\s\\S]*?)` に該当する内部の純粋なコード部分だけを切り取って返す
            return nsString.substring(with: match.range(at: 1))
        }
        return nil
    }
    
    /// 抽出されたAppleScript文字列をシステム（macOS）に解釈させ、実際に実行する関数
    /// - Parameter scriptString: 純粋なAppleScriptのコード文字列
    func executeAppleScript(_ scriptString: String) {
        // NSAppleScriptクラスのインスタンスを、ソースコード文字列を元に生成
        if let script = NSAppleScript(source: scriptString) {
            // エラー情報を受け取るための辞書オブジェクトのポインタを用意
            var error: NSDictionary?
            
            // スクリプトを実行。引数に `&error` を渡すことで、内部でエラーが起きた場合に情報を書き換えてもらう（参照渡し文法）
            script.executeAndReturnError(&error)
            
            // エラーオブジェクトが空（nil）でなければ、実行失敗としてコンソールに出力
            if let err = error { print("AppleScript実行エラー: \(err)") }
        }
    }
    
    /// キーボード等で手動入力されたテキストをそのままAIに投げる予備のボタンアクション
    @IBAction func buttonTapped(_ sender: Any) {
        let userInput = inputTextView.string
        self.outputTextView.string = "思考中..."
        processWithOllama(prompt: userInput)
    }
}
