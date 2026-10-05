import XCTest
@testable import TranslationCore

private actor LanguageProvider: TranslationProvider {
    var requests: [TranslationRequest] = []
    func complete(_ request: TranslationRequest) async throws -> String {
        requests.append(request); return request.source
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
}

final class TranslationLanguageTests: XCTestCase, @unchecked Sendable {
    func testEightLanguageTargetContractAndChineseDefault() {
        XCTAssertEqual(Set(TranslationLanguage.allCases.map(\.rawValue)), Set(["zh", "en", "ja", "ko", "fr", "de", "es", "ru"]))
        XCTAssertEqual(TranslationOptions().targetLanguage, TranslationLanguage.chinese.targetName)
        XCTAssertEqual(TranslationLanguage.sourceTitle("zh-Hant"), "中文")
        XCTAssertNil(TranslationLanguage.sourceTitle(nil))
        XCTAssertNil(TranslationLanguage.sourceTitle("und"))
    }
    func testOlderSavedOptionsNeedNoSourceLanguageField() throws {
        let data = try JSONEncoder().encode(TranslationOptions())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sourceLanguage")
        let restored = try JSONDecoder().decode(TranslationOptions.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.sourceLanguage)
        XCTAssertEqual(restored.targetLanguage, "简体中文")
    }
    func testAllLanguagePairsKeepAutomaticSourceAndTargetAcrossPipeline() async throws {
        for source in TranslationLanguage.allCases {
            for target in TranslationLanguage.allCases {
                let provider = LanguageProvider()
                let options = TranslationOptions(targetLanguage: target.targetName, quality: .publication, documentKind: .general, sourceLanguage: source.rawValue)
                _ = try await TranslationEngine().run(jobID: "\(source.rawValue)-\(target.rawValue)", source: "A complete passage with its original meaning.", options: options, provider: provider) { _ in }
                let requests = await provider.requests
                XCTAssertEqual(requests.map(\.stage), Quality.publication.stages)
                XCTAssertTrue(requests.allSatisfy { $0.options.sourceLanguage == source.rawValue && $0.options.targetLanguage == target.targetName })
            }
        }
    }
    #if canImport(NaturalLanguage)
    func testAutomaticRecognitionForEightLanguages() {
        let samples: [(TranslationLanguage, String)] = [
            (.chinese, "傍晚，她走进花园，听见树叶在风中轻轻摇动。朋友在门口等她，两人一起沿着小路走向河岸。"),
            (.english, "At dusk, she returned to the garden and watched the leaves move in the wind. Her friend waited near the gate, and they walked together towards the river."),
            (.japanese, "夕方、彼女は庭に戻り、風に揺れる木の葉を眺めていました。友人は門の近くで待っていて、二人は一緒に川へ続く道を歩きました。"),
            (.korean, "저녁이 되자 그녀는 정원으로 돌아와 바람에 흔들리는 나뭇잎을 바라보았습니다. 친구는 문 앞에서 기다리고 있었고 두 사람은 강을 향해 함께 걸었습니다."),
            (.french, "Au crépuscule, elle retourna dans le jardin et regarda les feuilles bouger dans le vent. Son amie l'attendait près de la porte, puis elles marchèrent ensemble vers la rivière."),
            (.german, "Am Abend kehrte sie in den Garten zurück und beobachtete die Blätter im Wind. Ihre Freundin wartete am Tor, und sie gingen gemeinsam auf dem kleinen Weg zum Fluss."),
            (.spanish, "Al atardecer, regresó al jardín y observó las hojas que se movían con el viento. Su amiga la esperaba cerca de la puerta y caminaron juntas hacia el río."),
            (.russian, "Вечером она вернулась в сад и посмотрела на листья, которые качались на ветру. Подруга ждала у ворот, и они вместе пошли по узкой дорожке к реке.")
        ]
        for (language, text) in samples {
            let code = SourceLanguageDetection.code(for: String(repeating: text + "\n", count: 3))
            XCTAssertEqual(TranslationLanguage.sourceTitle(code), language.title)
        }
        XCTAssertNil(SourceLanguageDetection.code(for: "123456789012345678901234567890"))
    }
    func testLanguageRecognitionSamplesBeyondEnglishFrontMatter() {
        let front = String(repeating: "Copyright notice. Table of contents. All rights reserved.\n", count: 100)
        let body = String(repeating: "Am Abend kehrte sie in den Garten zurück. Ihre Freundin wartete am Tor und erzählte von der Reise.\n", count: 400)
        XCTAssertEqual(TranslationLanguage.sourceTitle(SourceLanguageDetection.code(for: front + body)), "德语")
    }
    #endif
}
