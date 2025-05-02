pub const ClientError = error{
    ConnectionFailed,
    WriteFailed,
    ReadFailed,
    FramingFailed,
    DeserializeFailed,
    ResponseErrorStatus,
    RequestIdMismatch,
    InvalidResponseFormat,
    UnknownProcedure,
};
