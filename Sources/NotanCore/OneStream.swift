import Cmlx
import MLX

/// Runs `body` with MLX's core and MLX Swift working on the same GPU stream.
///
/// MLX Swift runs every operation on a GPU stream of its own. MLX's core, though, creates
/// a few operations by itself: the seed a derivative starts from, and the wrapping around
/// the results of a function with a hand-written derivative. Those go on the core's own
/// default stream, a different one. Work that passes from one stream to another has to be
/// synchronised between two GPU command queues, and in a fitting step that waiting came
/// to more than all the step's arithmetic.
///
/// So for the length of `body` the core's default stream, which is kept per thread, is set
/// to the one MLX Swift uses; afterwards the core's own is put back. MLX Swift has no call
/// for this, hence the use of MLX's C interface. Results are the same either way.
func onOneStream<T>(_ body: () throws -> T) rethrows -> T {
    let gpu = mlx_device_new_type(MLX_GPU, 0)
    var own = mlx_stream_new()
    mlx_get_default_stream(&own, gpu)
    mlx_set_default_stream(StreamOrDevice.default.ctx)
    defer {
        mlx_set_default_stream(own)
        mlx_stream_free(own)
        mlx_device_free(gpu)
    }
    return try body()
}
