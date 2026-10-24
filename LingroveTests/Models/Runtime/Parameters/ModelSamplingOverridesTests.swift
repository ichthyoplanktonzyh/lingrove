import Foundation
import Testing
@testable import Lingrove

struct ModelSamplingOverridesTests {
    @Test func untouchedValuesPreserveEachAdaptersDefaults() {
        for values in [ModelSamplingValues.speech, LearningInstructionSampling.standard.values,
                       LearningInstructionSampling.hyMT.values, LearningInstructionSampling.translateGemma.values] {
            #expect(values.applying(.init()) == values)
        }
    }
    @Test func malformedImportedValuesCannotReachNativeSampling() {
        let input = ModelSamplingOverrides(temperature: .infinity, topP: -1, topK: .max,
            repetitionPenalty: .nan, seedMode: .fixed, fixedSeed: .max)
        let result = ModelSamplingValues.speech.applying(input)
        #expect(result.temperature == 0.8 && result.topP == 0.01 && result.topK == 256)
        #expect(result.repetitionPenalty == 1 && result.seed == UInt32.max - 1)
        #expect(ModelSamplingOverrides(seedMode: .random).seed(recommended: 42) == .max)
    }
    @Test func endpointFieldsIgnoreDormantLocalPreferences() {
        let value = ModelSamplingOverrides(temperature: 0.2, topP: 0.8, topK: 5,
            repetitionPenalty: 1.2, seedMode: .fixed, fixedSeed: 9).endpointOnly
        #expect(value == .init(temperature: 0.2, topP: 0.8))
    }
}
