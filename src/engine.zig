pub const DfaSimulatorEngine = @import("engine/DfaSimulatorEngine.zig");
pub const ParallelDfaSimulatorEngine = @import("engine/ParallelDfaSimulatorEngine.zig");
pub const OpenCLEngine = @import("engine/OpenCLEngine.zig");
pub const HIPEngine = @import("engine/HIPEngine.zig");

test {
    _ = DfaSimulatorEngine;
    _ = ParallelDfaSimulatorEngine;
    // _ = OpenCLEngine;
    _ = HIPEngine;
}
