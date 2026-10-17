import Metal
import MLX
import Testing

@Suite("StemKit Metal runtime")
struct MetalRuntimeTests {
    @Test("MLX evaluates an operation on the Apple silicon GPU")
    func evaluatesGPUKernel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(!device.name.isEmpty)

        // Uses the same MLX Metal runtime as stem separation, without model
        // weights or network access. Missing kernels must fail CI, not skip.
        let left = MLXArray([Float(1), 2, 3])
        let right = MLXArray([Float(4), 5, 6])
        let result = MLX.add(left, right, stream: .gpu)
        MLX.eval(result)

        #expect(result.asArray(Float.self) == [5, 7, 9])
    }
}
