// build/examples.zig — example project build targets.

const std = @import("std");
const helpers = @import("helpers.zig");

pub fn addExamples(
    b: *std.Build,
    mer_worker_mod: *std.Build.Module,
    wasm_target: std.Build.ResolvedTarget,
) void {
    // ── sgdata Worker WASM ──────────────────────────────────────────────────
    const sgdata_mod = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    sgdata_mod.addImport("mer", mer_worker_mod);
    helpers.addDirModules(b, sgdata_mod, mer_worker_mod, "examples/singapore-data-dashboard/app", "app", &.{});
    helpers.addDirModules(b, sgdata_mod, mer_worker_mod, "examples/singapore-data-dashboard/api", "api", &.{});
    helpers.addRoutesModule(b, sgdata_mod, mer_worker_mod, "examples/singapore-data-dashboard/src/generated/routes.zig", "examples/singapore-data-dashboard/app", "examples/singapore-data-dashboard/api", &.{});
    const sgdata_wasm = b.addExecutable(.{
        .name = "merjs",
        .root_module = sgdata_mod,
    });
    sgdata_wasm.rdynamic = true;
    sgdata_wasm.entry = .disabled;
    sgdata_wasm.max_memory = helpers.wasm_max_memory;
    const install_sgdata = b.addInstallFile(sgdata_wasm.getEmittedBin(), "../examples/singapore-data-dashboard/worker/merjs.wasm");
    const sgdata_step = b.step("sgdata-worker", "Compile sgdata worker WASM");
    sgdata_step.dependOn(&install_sgdata.step);

    // ── Kanban example Worker WASM ──────────────────────────────────────────
    const kanban_mod = b.createModule(.{
        .root_source_file = b.path("src/worker.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    kanban_mod.addImport("mer", mer_worker_mod);
    const kanban_routes = b.createModule(.{
        .root_source_file = b.path("examples/kanban/routes.zig"),
    });
    kanban_routes.addImport("mer", mer_worker_mod);
    helpers.addDirModules(b, kanban_routes, mer_worker_mod, "examples/kanban/app", "app", &.{});
    kanban_mod.addImport("routes", kanban_routes);
    const kanban_wasm = b.addExecutable(.{
        .name = "merjs",
        .root_module = kanban_mod,
    });
    kanban_wasm.rdynamic = true;
    kanban_wasm.entry = .disabled;
    kanban_wasm.max_memory = helpers.wasm_max_memory;
    const install_kanban = b.addInstallFile(kanban_wasm.getEmittedBin(), "../examples/kanban/worker/merjs.wasm");
    const kanban_step = b.step("worker-example-kanban", "Compile kanban example worker WASM");
    kanban_step.dependOn(&install_kanban.step);
}
