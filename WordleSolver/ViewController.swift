import Cocoa
import WebKit
class ViewController: NSViewController, WKUIDelegate, WKNavigationDelegate {
    enum WordError: Error {
        case standard
    }
    
    var guesser: WordGuesser!
    var webView: WKWebView!
    var closedHelp = false
    var guessedWords = 0

    
    override func loadView() {
        
        
        
        ViewController.clean()
        guard let words = load(file: "words") else {
            return
        }
        let wordsArray = words.split(separator: "\n").map { String($0) }
        self.guesser = WordGuesser(words: wordsArray, optimize: true)
        
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        webView.uiDelegate = self
        webView.navigationDelegate = self
        view = webView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let myURL = URL(string:"https://www.powerlanguage.co.uk/wordle/")
        let myRequest = URLRequest(url: myURL!)
        webView.load(myRequest)
    }
    
    func closeHelp() {
        webView.evaluateJavaScript("document.querySelector('game-app').shadowRoot.querySelector('game-theme-manager').querySelector('game-modal').shadowRoot.querySelector('game-icon').click()", completionHandler: nil)
        closedHelp = true
    }
    
    func pressKey(_ key: String) {
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript("window.dispatchEvent(new KeyboardEvent('keydown', {'key': '\(key)'}));")
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !closedHelp {
            closeHelp()
        }
        Task {
            await startLoop()
        }
    }
    
    func startLoop() async {
        
        guessWord(guesser.giveGuess())
        guessedWords += 1
        sleep(2)
        let results = await getResults(guessedWords-1)
        print(results)
        
        if results.allSatisfy({ $0.type == .correct }) {
            print("correct!")
        } else {
            guesser.handleResults(results)
            await startLoop()
        }
        
    }
    
    func guessWord(_ word: String) {
        word.forEach { character in
            pressKey(String(character))
            usleep(300000)
        }
        
        pressKey("Enter")
    }
    
    func getResults(_ guess: Int) async -> [GuessResult] {
        var results = [GuessResult]()
        for i in 0..<5 {
            if let result = try? await getResultForCharacter(i, inWord: guess) {
                results.append(result)
            }
        }
        return results
    }
    
    func getResultForCharacter(_ characterIndex: Int, inWord word: Int) async throws -> GuessResult? {
        let stateString = try await webView.evaluateJavaScript("document.querySelector('game-app').shadowRoot.querySelector('game-theme-manager').querySelector('#board').childNodes[\(word)].shadowRoot.querySelector('.row').children[\(characterIndex)].getAttribute('evaluation')") as! String
        
        let character = try await webView.evaluateJavaScript("document.querySelector('game-app').shadowRoot.querySelector('game-theme-manager').querySelector('#board').childNodes[\(word)].shadowRoot.querySelector('.row').children[\(characterIndex)].getAttribute('letter')") as! String
        
        guard let state = GuessResult.ResultType(rawValue: stateString) else {
            return nil
        }
        
        return GuessResult(type: state, character: character, index: characterIndex)
    }
    
    class func clean() {
        HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
        print("[WebCacheCleaner] All cookies deleted")
        
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            records.forEach { record in
                WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record], completionHandler: {})
                print("[WebCacheCleaner] Record \(record) deleted")
            }
        }
    }
    
    func load(file named: String) -> String? {
        guard let fileUrl = Bundle.main.url(forResource: named, withExtension: "txt") else {
            return nil
        }
        
        guard let content = try? String(contentsOf: fileUrl, encoding: .utf8) else {
            return nil
        }
        
        return content
    }

}


struct GuessResult {
    enum ResultType: String {
        case absent
        case present
        case correct
    }
    
    let type: ResultType
    let character: String
    let index: Int
}

struct WordGuesser {
    var words: [String]
    var letterRank = ["e", "a", "r", "i", "o", "t", "n", "s", "l", "c", "u", "d", "p",
                      "m", "h", "g", "b", "f", "y", "w", "k", "v", "x", "z", "j", "q"]
    let optimize: Bool
    
    init(words: [String], optimize: Bool = true) {
        self.words = words
        self.optimize = optimize
    }
    
    mutating func handleResults(_ results: [GuessResult]) {
        // Bug in game where 2nd duplicate letter shows absent
        let letters = results.map { $0.character }
        let dupes = Dictionary(grouping: letters, by: {$0}).filter { $1.count > 1 }.keys
        
        guard dupes.isEmpty else {
            var resultsCopy = results
            for dupe in dupes {
                if resultsCopy.contains(where: { result in
                    result.character == dupe && (result.type == .correct || result.type == .present)
                }) {
                    resultsCopy.removeAll { result in
                        result.character == dupe && result.type == .absent
                    }
                }
            }

            for result in resultsCopy {
                handleResult(result)
            }
            return
        }
        
        for result in results {
            handleResult(result)
        }
    }
    
    mutating func handleResult(_ result: GuessResult) {
        switch result.type {
        case .correct:
            words.removeAll { word in
                let characters = Array(word).map {String($0)}
                return characters[result.index] != result.character
            }
        case .absent:
            words.removeAll { word in
                let characters = Array(word).map {String($0)}
                return characters.contains { character in
                    character == result.character
                }
            }
            if let index = letterRank.firstIndex(of: result.character) {
                letterRank.remove(at: index)
            }
        case .present:
            // remove all words that have that character in that position
            words.removeAll { word in
                let characters = Array(word).map {String($0)}
                return characters[result.index] == result.character
            }
            
            // remove all words that don't have that character at all
            words.removeAll { word in
                let characters = Array(word).map {String($0)}
                return characters.allSatisfy { character in
                    character != result.character
                }
            }
            if let index = letterRank.firstIndex(of: result.character) {
                letterRank.remove(at: index)
            }
        }
        print(self.words.count)
        print(self.words)
    }
    
    func giveGuess() -> String {
        if !optimize {
            return words.randomElement()!
        }
        
        // try using words with common letters
        var wordsCopy = words
        var wordsCandidates = wordsCopy
        var index = 0
        
        while !wordsCandidates.isEmpty {
            wordsCopy = wordsCandidates
            wordsCandidates.removeAll { word in
                !word.contains(letterRank[index])
            }
            index += 1
        }
        
        return wordsCopy.randomElement()!
    }
    
    func countWords() -> Int {
        return words.count
    }
}
