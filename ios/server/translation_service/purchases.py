from dataclasses import dataclass
import hashlib
from pathlib import Path
import time
import uuid

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.Type import Type
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier, VerificationException

from .config import Settings
from .ledger import PRODUCTS, ServiceError


@dataclass(frozen=True)
class VerifiedPurchase:
    transaction_key: str
    product_id: str
    jws_hash: str


class ApplePurchaseVerifier:
    def __init__(self, settings: Settings):
        roots = [Path(path).read_bytes() for path in settings.apple_root_paths]
        self.verifier = SignedDataVerifier(roots, True, Environment(settings.apple_environment), settings.apple_bundle_id, settings.apple_app_id)
        self.environment = settings.apple_environment

    def verify(self, signed_transaction: str, account_id: str) -> VerifiedPurchase:
        try:
            payload = self.verifier.verify_and_decode_signed_transaction(signed_transaction)
        except VerificationException:
            raise ServiceError(400, "Apple 购买凭据签名验证失败。") from None
        product = payload.productId
        if product not in PRODUCTS:
            raise ServiceError(400, "不支持的 App Store 商品。")
        if payload.revocationDate is not None:
            raise ServiceError(400, "此购买已撤销或退款。")
        expected_type = Type.NON_CONSUMABLE if product == "app.bookllm.byok.lifetime" else Type.CONSUMABLE
        if payload.type != expected_type or payload.quantity != 1:
            raise ServiceError(400, "商品类型或购买数量无效。")
        try:
            token = str(uuid.UUID(payload.appAccountToken))
        except (ValueError, TypeError, AttributeError):
            raise ServiceError(403, "购买未绑定云端账户。点数购买必须登录并设置 appAccountToken。") from None
        if token != account_id:
            raise ServiceError(403, "此购买属于其他账户。")
        if not payload.transactionId or len(payload.transactionId) > 128:
            raise ServiceError(400, "购买交易编号无效。")
        if payload.purchaseDate is None or payload.purchaseDate > (time.time() + 60) * 1000:
            raise ServiceError(400, "购买时间无效。")
        return VerifiedPurchase(f"{self.environment}:{payload.transactionId}", product, hashlib.sha256(signed_transaction.encode()).hexdigest())

    def notification(self, signed_payload: str):
        try:
            notification = self.verifier.verify_and_decode_notification(signed_payload)
            notification_type = notification.notificationType.value if notification.notificationType else None
            if notification_type not in ("REFUND", "REVOKE", "REFUND_REVERSED"):
                return None
            if not notification.data or not notification.data.signedTransactionInfo:
                raise ServiceError(400, "通知缺少交易信息。")
            payload = self.verifier.verify_and_decode_signed_transaction(notification.data.signedTransactionInfo)
            if payload.productId not in PRODUCTS or not payload.transactionId:
                raise ServiceError(400, "通知商品或交易编号无效。")
            if not notification.notificationUUID or notification.signedDate is None:
                raise ServiceError(400, "通知标识或签名时间无效。")
            if notification.signedDate > (time.time() + 60) * 1000:
                raise ServiceError(400, "通知时间无效。")
            return (f"{self.environment}:{payload.transactionId}", notification_type != "REFUND_REVERSED", notification.signedDate, notification.notificationUUID)
        except VerificationException:
            raise ServiceError(400, "Apple 通知签名验证失败。") from None
