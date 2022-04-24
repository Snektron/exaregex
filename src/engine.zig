pub const DfaSimulatorEngine = @import("engine/DfaSimulatorEngine.zig");
pub const ParallelDfaSimulatorEngine = @import("engine/ParallelDfaSimulatorEngine.zig");

test "" {
    _ = DfaSimulatorEngine;
    _ = ParallelDfaSimulatorEngine;
}
