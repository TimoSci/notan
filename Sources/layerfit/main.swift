import Foundation

FileHandle.standardError.write(
    Data("usage: layerfit <image> <outdir> [--mode refit|prefix] [--shapes N] [--size N] [--steps N]\n".utf8))
exit(1)
