import Foundation
import MLX

/// Adam on a list of plain arrays, with one learning rate per array. MLX's own optimiser
/// is built around neural-network modules; here the set of trainable arrays changes every
/// stage, so a small one of our own is simpler. Gradients still come from MLX.
public struct Adam {
    public let learningRates: [Float]
    public let beta1: Float
    public let beta2: Float
    public let eps: Float

    private var first: [MLXArray] = []
    private var second: [MLXArray] = []
    private var stepCount = 0

    public init(learningRates: [Float], beta1: Float = 0.9, beta2: Float = 0.999, eps: Float = 1e-8) {
        self.learningRates = learningRates
        self.beta1 = beta1
        self.beta2 = beta2
        self.eps = eps
    }

    public mutating func step(parameters: [MLXArray], gradients: [MLXArray]) -> [MLXArray] {
        precondition(parameters.count == learningRates.count && gradients.count == parameters.count)
        if first.isEmpty {
            first = parameters.map { MLXArray.zeros($0.shape) }
            second = parameters.map { MLXArray.zeros($0.shape) }
        }
        stepCount += 1
        let correction1 = 1 - pow(beta1, Float(stepCount))
        let correction2 = 1 - pow(beta2, Float(stepCount))
        var updated: [MLXArray] = []
        for index in parameters.indices {
            let gradient = gradients[index]
            first[index] = beta1 * first[index] + (1 - beta1) * gradient
            second[index] = beta2 * second[index] + (1 - beta2) * gradient * gradient
            let mean = first[index] / correction1
            let variance = second[index] / correction2
            updated.append(parameters[index] - learningRates[index] * mean / (sqrt(variance) + eps))
        }
        eval(first + second)
        return updated
    }

    /// Drops the momentum of some elements of one parameter: `keeping`, the same shape as
    /// the parameter, is 0 for those and 1 for the rest. For elements whose last step was
    /// undone, so that the next step does not simply make the same move again.
    public mutating func forget(parameter: Int, keeping: MLXArray) {
        guard first.indices.contains(parameter) else { return }
        first[parameter] = first[parameter] * keeping
        eval(first[parameter])
    }
}
