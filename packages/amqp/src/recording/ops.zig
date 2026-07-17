pub const Ops = enum {
    unknown,
    open_channel,
    close_channel,
    declare_ephemeral_queue,
    declare_durable_queue,
    bind,
    unbind,
    publish,
};
