const std = @import("std");
const windows = std.os.windows;
const HANDLE = windows.HANDLE;

const BasicLimits = extern struct {
    process_time: i64 = 0,
    job_time: i64 = 0,
    flags: u32 = 0,
    min_working_set: usize = 0,
    max_working_set: usize = 0,
    active_processes: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};

const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io_counters: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};

extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: i32, info: *const ExtendedLimits, size: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) windows.BOOL;

pub const Job = struct {
    handle: ?HANDLE,

    pub fn init() !Job {
        const handle = CreateJobObjectW(null, null) orelse return error.WindowsJobCreateFailed;
        errdefer windows.CloseHandle(handle);
        const kill_on_close = 0x2000;
        const extended_limit_information = 9;
        const limits: ExtendedLimits = .{ .basic = .{ .flags = kill_on_close } };
        if (SetInformationJobObject(handle, extended_limit_information, &limits, @sizeOf(ExtendedLimits)) == .FALSE)
            return error.WindowsJobConfigureFailed;
        return .{ .handle = handle };
    }

    pub fn start(job: Job, child: *const std.process.Child) !void {
        // The suspended child cannot run or create descendants until it belongs to the job.
        if (AssignProcessToJobObject(job.handle.?, child.id.?) == .FALSE) return error.WindowsJobAssignFailed;
        if (windows.ntdll.NtResumeThread(child.thread_handle, null) != .SUCCESS) return error.WindowsChildResumeFailed;
    }

    pub fn close(job: *Job) void {
        if (job.handle) |handle| windows.CloseHandle(handle);
        job.handle = null;
    }
};
