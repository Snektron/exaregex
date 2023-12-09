pub const DfaSimulatorEngine = @import("engine/DfaSimulatorEngine.zig");
pub const ParallelDfaSimulatorEngine = @import("engine/ParallelDfaSimulatorEngine.zig");
pub const OpenCLEngine = @import("engine/OpenCLEngine.zig");

test {
    _ = DfaSimulatorEngine;
    _ = ParallelDfaSimulatorEngine;
    _ = OpenCLEngine;
}
