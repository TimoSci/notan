import MLX
import XCTest
@testable import LayerFitCore

final class AdamTests: XCTestCase {
    func testAdamMinimisesQuadratic() {
        var adam = Adam(learningRates: [0.1])
        var x = MLXArray([0.0] as [Float])
        let gradient = grad { (x: MLXArray) in ((x - 3) * (x - 3)).sum() }
        for _ in 0..<200 {
            x = adam.step(parameters: [x], gradients: [gradient(x)])[0]
            eval(x)
        }
        XCTAssertEqual(x.item(Float.self), 3, accuracy: 0.05)
    }

    func testFirstStepMovesByLearningRate() {
        // Adam's bias correction makes the first step exactly lr * sign(gradient).
        var adam = Adam(learningRates: [0.5])
        let x = adam.step(
            parameters: [MLXArray([10.0, 10.0] as [Float])],
            gradients: [MLXArray([4.0, -0.001] as [Float])])[0]
        let values = x.asArray(Float.self)
        XCTAssertEqual(values[0], 9.5, accuracy: 1e-3)
        XCTAssertEqual(values[1], 10.5, accuracy: 1e-3)
    }

    func testAdamPerParameterRates() {
        var adam = Adam(learningRates: [0.1, 0])
        let a = MLXArray([1.0] as [Float])
        let b = MLXArray([1.0] as [Float])
        let updated = adam.step(
            parameters: [a, b], gradients: [MLXArray([2.0] as [Float]), MLXArray([2.0] as [Float])])
        XCTAssertNotEqual(updated[0].item(Float.self), 1)
        XCTAssertEqual(updated[1].item(Float.self), 1)
    }
}
