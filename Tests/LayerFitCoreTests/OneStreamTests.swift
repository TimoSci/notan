import Cmlx
import MLX
import XCTest

@testable import LayerFitCore

final class OneStreamTests: XCTestCase {
    /// The stream MLX's core uses, on this thread, for operations it creates by itself.
    func coreStream() -> mlx_stream {
        let gpu = mlx_device_new_type(MLX_GPU, 0)
        defer { mlx_device_free(gpu) }
        var stream = mlx_stream_new()
        mlx_get_default_stream(&stream, gpu)
        return stream
    }

    /// The reason `onOneStream` exists. If this fails after an MLX update, the core has
    /// started using MLX Swift's stream by itself and `onOneStream` is no longer needed.
    func testTheCoreHasADefaultStreamOfItsOwn() {
        XCTAssertFalse(mlx_stream_equal(coreStream(), StreamOrDevice.default.ctx))
    }

    func testInsideTheCoreUsesMLXSwiftsStream() {
        let same = onOneStream { mlx_stream_equal(coreStream(), StreamOrDevice.default.ctx) }
        XCTAssertTrue(same)
    }

    func testAfterwardsTheCoresOwnStreamIsBack() {
        let before = coreStream()
        let nested = onOneStream {
            onOneStream { mlx_stream_equal(coreStream(), StreamOrDevice.default.ctx) }
                && mlx_stream_equal(coreStream(), StreamOrDevice.default.ctx)
        }
        XCTAssertTrue(nested)
        XCTAssertTrue(mlx_stream_equal(coreStream(), before))
    }

    func testResultsComeOutTheSame() {
        let a = MLXArray([1, 2, 3] as [Float])
        let plain = valueAndGrad { (x: [MLXArray]) in [(x[0] * x[0]).sum()] }([a]).1[0]
        let aligned = onOneStream {
            valueAndGrad { (x: [MLXArray]) in [(x[0] * x[0]).sum()] }([a]).1[0]
        }
        XCTAssertEqual(plain.asArray(Float.self), [2, 4, 6])
        XCTAssertEqual(aligned.asArray(Float.self), [2, 4, 6])
    }
}
