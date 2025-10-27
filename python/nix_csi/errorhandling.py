import logging
from grpclib.const import Status
from grpclib.exceptions import GRPCError
from typing import Optional, Any

logger = logging.getLogger("nix-csi")


class NixCsiError(GRPCError):
    def __init__(
        self,
        status: Status,
        message: Optional[str] = None,
        details: Any = None,
    ) -> None:
        logger.error(message)
        super().__init__(status, message, details)
        self.status = status
        self.message = message
        self.details = details
