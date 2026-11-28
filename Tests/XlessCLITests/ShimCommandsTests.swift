import Foundation
import Testing
@testable import xless

/// `strip`'s LLVM: installed beside the shims (`<XLESS_SHIM_DIR>/../llvm/bin`), not at a path of the image.
@Test func theStripShimFindsLLVMBesideTheShims() {
    #expect(StripShimCommand.llvmStrip(shims: "/opt/xless/shims") == "/opt/xless/llvm/bin/llvm-strip")
    #expect(StripShimCommand.llvmStrip(shims: "/elsewhere/shims/") == "/elsewhere/llvm/bin/llvm-strip")
    #expect(StripShimCommand.llvmStrip(shims: nil) == "llvm-strip" && StripShimCommand.llvmStrip(shims: "") == "llvm-strip")
}
