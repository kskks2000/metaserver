from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, time, timedelta
from decimal import Decimal, InvalidOperation
from functools import lru_cache
from threading import Lock
from typing import Any
from zoneinfo import ZoneInfo

import httpx

from app.core.config import Settings, get_settings
from app.schemas.trading import (
    BrokerEnvironment,
    DomesticStockOrderRequest,
    DomesticStockOrderResponse,
    DomesticStockQuoteResponse,
    KisConnectionStatusResponse,
    KisPortfolioHolding,
    KisPortfolioResponse,
    OrderKind,
    OrderSide,
)


class KisConfigurationError(RuntimeError):
    """Raised when the KIS integration is not ready to make a request."""


class KisOrderValidationError(RuntimeError):
    """Raised before a KIS order is sent when the app cannot support it safely."""


class KisApiError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        error_code: str | None = None,
        payload: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error_code = error_code
        self.payload = payload or {}


@dataclass(frozen=True)
class KisCredentials:
    environment: BrokerEnvironment
    app_key: str
    app_secret: str
    account_no: str
    product_code: str
    base_url: str
    user_agent: str


@dataclass
class KisToken:
    access_token: str
    expires_at: datetime


class KisClient:
    TOKEN_PATH = "/oauth2/tokenP"
    HASHKEY_PATH = "/uapi/hashkey"
    QUOTE_PATH = "/uapi/domestic-stock/v1/quotations/inquire-price"
    ORDER_PATH = "/uapi/domestic-stock/v1/trading/order-cash"
    BALANCE_PATH = "/uapi/domestic-stock/v1/trading/inquire-balance"
    KST = ZoneInfo("Asia/Seoul")
    REGULAR_SESSION_START = time(9, 0)
    REGULAR_SESSION_END = time(15, 30)

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client = httpx.Client(timeout=settings.kis_timeout_seconds)
        self._tokens: dict[BrokerEnvironment, KisToken] = {}
        self._token_lock = Lock()

    def status(self) -> KisConnectionStatusResponse:
        environment = BrokerEnvironment(self._settings.kis_default_environment)
        try:
            credentials = self._credentials(environment)
        except KisConfigurationError as exc:
            return KisConnectionStatusResponse(
                configured=False,
                default_environment=environment,
                live_trading_enabled=self._settings.kis_live_trading_enabled,
                order_protocol=self._settings.kis_order_protocol,
                message=str(exc),
            )

        return KisConnectionStatusResponse(
            configured=True,
            default_environment=environment,
            live_trading_enabled=self._settings.kis_live_trading_enabled,
            order_protocol=self._settings.kis_order_protocol,
            account_no_masked=self._mask_full_account(credentials),
            product_code=credentials.product_code,
            base_url=credentials.base_url,
        )

    def quote_domestic_stock(
        self,
        *,
        symbol: str,
        market_code: str = "J",
        environment: BrokerEnvironment | None = None,
    ) -> DomesticStockQuoteResponse:
        env = environment or BrokerEnvironment(self._settings.kis_default_environment)
        credentials = self._credentials(env)
        data = self._request(
            credentials,
            "GET",
            self.QUOTE_PATH,
            tr_id="FHKST01010100",
            params={
                "FID_COND_MRKT_DIV_CODE": market_code,
                "FID_INPUT_ISCD": symbol,
            },
        )
        output = self._as_dict(data.get("output"))
        return DomesticStockQuoteResponse(
            environment=env,
            market_code=market_code,
            symbol=symbol,
            price=self._decimal(output.get("stck_prpr")),
            previous_close=self._decimal(output.get("stck_sdpr")),
            change_price=self._decimal(output.get("prdy_vrss")),
            change_rate=self._decimal(output.get("prdy_ctrt")),
            open_price=self._decimal(output.get("stck_oprc")),
            high_price=self._decimal(output.get("stck_hgpr")),
            low_price=self._decimal(output.get("stck_lwpr")),
            accumulated_volume=self._decimal(output.get("acml_vol")),
            accumulated_trade_amount=self._decimal(output.get("acml_tr_pbmn")),
            raw_output=output,
        )

    def portfolio(
        self,
        environment: BrokerEnvironment | None = None,
    ) -> KisPortfolioResponse:
        env = environment or BrokerEnvironment(self._settings.kis_default_environment)
        credentials = self._credentials(env)
        params = {
            "CANO": credentials.account_no,
            "ACNT_PRDT_CD": credentials.product_code,
            "AFHR_FLPR_YN": "N",
            "OFL_YN": "",
            "INQR_DVSN": "02",
            "UNPR_DVSN": "01",
            "FUND_STTL_ICLD_YN": "N",
            "FNCG_AMT_AUTO_RDPT_YN": "N",
            "PRCS_DVSN": "00",
            "CTX_AREA_FK100": "",
            "CTX_AREA_NK100": "",
        }
        output1: list[dict[str, Any]] = []
        summaries: list[dict[str, Any]] = []
        tr_cont = ""
        for _ in range(10):
            data, response_headers = self._request_with_headers(
                credentials,
                "GET",
                self.BALANCE_PATH,
                tr_id=self._balance_tr_id(env),
                tr_cont=tr_cont,
                params=params,
            )
            output1.extend(self._as_list(data.get("output1")))
            page_summary = self._first_dict(data.get("output2"))
            if page_summary:
                summaries.append(page_summary)

            next_tr_cont = str(response_headers.get("tr_cont") or "").strip()
            if next_tr_cont not in {"F", "M"}:
                break

            params["CTX_AREA_FK100"] = self._context_value(
                data, page_summary, "ctx_area_fk100"
            )
            params["CTX_AREA_NK100"] = self._context_value(
                data, page_summary, "ctx_area_nk100"
            )
            if not params["CTX_AREA_FK100"] and not params["CTX_AREA_NK100"]:
                break
            tr_cont = "N"

        output2 = summaries[0] if summaries else {}

        holdings: list[KisPortfolioHolding] = []
        for item in output1:
            quantity = self._decimal(item.get("hldg_qty")) or Decimal("0")
            if quantity <= 0:
                continue

            current_price = self._decimal(item.get("prpr"))
            average_price = self._decimal(item.get("pchs_avg_pric"))
            purchase_amount = self._decimal(item.get("pchs_amt"))
            evaluation_amount = self._decimal(item.get("evlu_amt"))
            profit_loss = self._decimal(item.get("evlu_pfls_amt"))
            profit_loss_rate = self._decimal(item.get("evlu_pfls_rt"))

            if evaluation_amount is None and current_price is not None:
                evaluation_amount = current_price * quantity
            if (
                profit_loss is None
                and evaluation_amount is not None
                and purchase_amount is not None
            ):
                profit_loss = evaluation_amount - purchase_amount
            if (
                profit_loss_rate is None
                and profit_loss is not None
                and purchase_amount is not None
                and purchase_amount != 0
            ):
                profit_loss_rate = (profit_loss / purchase_amount) * Decimal("100")

            holdings.append(
                KisPortfolioHolding(
                    symbol=str(item.get("pdno") or ""),
                    name=str(
                        item.get("prdt_name")
                        or item.get("prdt_name120")
                        or item.get("pdno")
                        or ""
                    ),
                    quantity=quantity,
                    orderable_quantity=self._decimal(item.get("ord_psbl_qty")),
                    average_price=average_price,
                    current_price=current_price,
                    purchase_amount=purchase_amount,
                    evaluation_amount=evaluation_amount,
                    profit_loss=profit_loss,
                    profit_loss_rate=profit_loss_rate,
                    raw_output=item,
                )
            )

        total_purchase_amount = self._decimal_first(
            output2,
            "pchs_amt_smtl_amt",
            "tot_pchs_amt",
        )
        total_evaluation_amount = self._decimal_first(
            output2,
            "nass_amt",
            "tot_evlu_amt",
            "scts_evlu_amt",
        )
        total_profit_loss = self._decimal_first(
            output2,
            "evlu_pfls_smtl_amt",
            "evlu_pfls_amt",
        )
        profit_loss_rate = self._decimal_first(output2, "evlu_erng_rt", "evlu_pfls_rt")
        orderable_cash = self._decimal_first(
            output2,
            "ord_psbl_cash",
            "ord_psbl_amt",
            "dnca_tot_amt",
            "nxdy_excc_amt",
        )

        if total_purchase_amount is None:
            total_purchase_amount = sum(
                (holding.purchase_amount or Decimal("0")) for holding in holdings
            )
        if total_evaluation_amount is None:
            total_evaluation_amount = sum(
                (holding.evaluation_amount or Decimal("0")) for holding in holdings
            )
        if total_profit_loss is None:
            total_profit_loss = sum(
                (holding.profit_loss or Decimal("0")) for holding in holdings
            )
        if (
            profit_loss_rate is None
            and total_profit_loss is not None
            and total_purchase_amount is not None
            and total_purchase_amount != 0
        ):
            profit_loss_rate = (total_profit_loss / total_purchase_amount) * Decimal("100")

        return KisPortfolioResponse(
            environment=env,
            account_no_masked=self._mask_full_account(credentials),
            holdings=holdings,
            total_purchase_amount=total_purchase_amount,
            total_evaluation_amount=total_evaluation_amount,
            total_profit_loss=total_profit_loss,
            profit_loss_rate=profit_loss_rate,
            orderable_cash=orderable_cash,
            raw_summary=output2,
        )

    def place_domestic_stock_order(
        self,
        payload: DomesticStockOrderRequest,
    ) -> DomesticStockOrderResponse:
        env = payload.environment or BrokerEnvironment(self._settings.kis_default_environment)
        credentials = self._credentials(env)
        if (
            env == BrokerEnvironment.live
            and not self._settings.kis_live_trading_enabled
            and not payload.dry_run
        ):
            raise KisConfigurationError(
                "Live KIS orders are disabled. Set KIS_LIVE_TRADING_ENABLED=true to allow them."
            )

        order_division = payload.order_division_code or self._order_division(payload)
        if not payload.dry_run:
            self._validate_supported_order_session(payload, order_division)
        order_price = self._order_price(payload, order_division)
        tr_id = self._order_tr_id(env, payload.side)
        request_payload = self._order_payload(
            credentials=credentials,
            payload=payload,
            order_division=order_division,
            order_price=order_price,
        )

        if payload.dry_run:
            return self._order_response(
                payload=payload,
                env=env,
                tr_id=tr_id,
                order_division=order_division,
                order_price=order_price,
                request_payload=request_payload,
                data={"rt_cd": "0", "msg_cd": "DRY_RUN", "msg1": "Dry run only."},
                raw_output={},
                dry_run=True,
            )

        data = self._request(
            credentials,
            "POST",
            self.ORDER_PATH,
            tr_id=tr_id,
            json_payload=request_payload,
            include_hashkey=self._settings.kis_include_hashkey,
        )
        raw_output = self._as_dict(data.get("output"))
        return self._order_response(
            payload=payload,
            env=env,
            tr_id=tr_id,
            order_division=order_division,
            order_price=order_price,
            request_payload=request_payload,
            data=data,
            raw_output=raw_output,
            dry_run=False,
        )

    def _request(
        self,
        credentials: KisCredentials,
        method: str,
        path: str,
        *,
        tr_id: str,
        params: dict[str, Any] | None = None,
        json_payload: dict[str, Any] | None = None,
        include_hashkey: bool = False,
        tr_cont: str = "",
    ) -> dict[str, Any]:
        data, _ = self._request_with_headers(
            credentials,
            method,
            path,
            tr_id=tr_id,
            params=params,
            json_payload=json_payload,
            include_hashkey=include_hashkey,
            tr_cont=tr_cont,
        )
        return data

    def _request_with_headers(
        self,
        credentials: KisCredentials,
        method: str,
        path: str,
        *,
        tr_id: str,
        params: dict[str, Any] | None = None,
        json_payload: dict[str, Any] | None = None,
        include_hashkey: bool = False,
        tr_cont: str = "",
    ) -> tuple[dict[str, Any], httpx.Headers]:
        token = self._access_token(credentials)
        headers = self._headers(credentials, token.access_token, tr_id)
        headers["tr_cont"] = tr_cont
        if include_hashkey and json_payload is not None:
            headers["hashkey"] = self._hashkey(credentials, token.access_token, json_payload)

        try:
            response = self._client.request(
                method,
                f"{credentials.base_url}{path}",
                headers=headers,
                params=params,
                json=json_payload,
            )
        except httpx.HTTPError as exc:
            raise KisApiError(f"KIS request failed: {exc}") from exc

        data = self._decode_json(response)
        if response.status_code != 200:
            message = data.get("msg1") or response.text
            raise KisApiError(
                str(message),
                status_code=response.status_code,
                error_code=data.get("msg_cd"),
                payload=data,
            )

        if data.get("rt_cd") not in (None, "0"):
            raise KisApiError(
                str(data.get("msg1") or "KIS API returned an error."),
                status_code=response.status_code,
                error_code=data.get("msg_cd"),
                payload=data,
            )
        return data, response.headers

    def _access_token(self, credentials: KisCredentials) -> KisToken:
        now = datetime.now()
        cached = self._tokens.get(credentials.environment)
        if cached and cached.expires_at > now + timedelta(minutes=1):
            return cached

        with self._token_lock:
            cached = self._tokens.get(credentials.environment)
            if cached and cached.expires_at > datetime.now() + timedelta(minutes=1):
                return cached

            response = self._client.post(
                f"{credentials.base_url}{self.TOKEN_PATH}",
                headers=self._base_headers(credentials),
                json={
                    "grant_type": "client_credentials",
                    "appkey": credentials.app_key,
                    "appsecret": credentials.app_secret,
                },
            )
            data = self._decode_json(response)
            if response.status_code != 200 or "access_token" not in data:
                raise KisApiError(
                    str(data.get("msg1") or response.text or "Failed to issue KIS token."),
                    status_code=response.status_code,
                    error_code=data.get("msg_cd"),
                    payload=data,
                )

            expires_at = self._parse_token_expiry(data)
            token = KisToken(access_token=str(data["access_token"]), expires_at=expires_at)
            self._tokens[credentials.environment] = token
            return token

    def _hashkey(
        self,
        credentials: KisCredentials,
        access_token: str,
        payload: dict[str, Any],
    ) -> str:
        headers = self._base_headers(credentials)
        headers["authorization"] = f"Bearer {access_token}"
        headers["appkey"] = credentials.app_key
        headers["appsecret"] = credentials.app_secret
        response = self._client.post(
            f"{credentials.base_url}{self.HASHKEY_PATH}",
            headers=headers,
            json=payload,
        )
        data = self._decode_json(response)
        if response.status_code != 200 or "HASH" not in data:
            raise KisApiError(
                str(data.get("msg1") or response.text or "Failed to create KIS hashkey."),
                status_code=response.status_code,
                error_code=data.get("msg_cd"),
                payload=data,
            )
        return str(data["HASH"])

    def _credentials(self, environment: BrokerEnvironment) -> KisCredentials:
        app_key = self._env_value(environment, "app_key")
        app_secret = self._env_value(environment, "app_secret")
        account_raw = self._env_value(environment, "account_no")
        product_code = self._env_value(environment, "account_product_code")
        if not product_code:
            product_code = self._settings.kis_account_product_code

        missing = [
            name
            for name, value in {
                "KIS app key": app_key,
                "KIS app secret": app_secret,
                "KIS account number": account_raw,
            }.items()
            if not value
        ]
        if missing:
            raise KisConfigurationError(f"Missing {', '.join(missing)}.")

        account_no, product_code = self._split_account(str(account_raw), str(product_code))
        base_url = (
            self._settings.kis_live_base_url
            if environment == BrokerEnvironment.live
            else self._settings.kis_paper_base_url
        )
        return KisCredentials(
            environment=environment,
            app_key=str(app_key),
            app_secret=str(app_secret),
            account_no=account_no,
            product_code=product_code,
            base_url=base_url.rstrip("/"),
            user_agent=self._settings.kis_user_agent,
        )

    def _env_value(self, environment: BrokerEnvironment, suffix: str) -> str | None:
        env_prefix = "live" if environment == BrokerEnvironment.live else "paper"
        specific = getattr(self._settings, f"kis_{env_prefix}_{suffix}", None)
        return specific or getattr(self._settings, f"kis_{suffix}", None)

    @staticmethod
    def _split_account(account_raw: str, product_code: str) -> tuple[str, str]:
        account = "".join(ch for ch in account_raw if ch.isalnum())
        if len(account) >= 10:
            return account[:8], account[8:10]
        if len(account) == 8:
            return account, product_code
        raise KisConfigurationError(
            "KIS account number must be 8 digits or a full 10 digit account/product value."
        )

    def _base_headers(self, credentials: KisCredentials) -> dict[str, str]:
        return {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "charset": "UTF-8",
            "User-Agent": credentials.user_agent,
        }

    def _headers(
        self,
        credentials: KisCredentials,
        access_token: str,
        tr_id: str,
    ) -> dict[str, str]:
        headers = self._base_headers(credentials)
        headers["authorization"] = f"Bearer {access_token}"
        headers["appkey"] = credentials.app_key
        headers["appsecret"] = credentials.app_secret
        headers["tr_id"] = tr_id
        headers["custtype"] = "P"
        headers["tr_cont"] = ""
        return headers

    def _order_tr_id(self, environment: BrokerEnvironment, side: OrderSide) -> str:
        if self._settings.kis_order_protocol == "legacy":
            if environment == BrokerEnvironment.live:
                return "TTTC0802U" if side == OrderSide.buy else "TTTC0801U"
            return "VTTC0802U" if side == OrderSide.buy else "VTTC0801U"

        if environment == BrokerEnvironment.live:
            return "TTTC0012U" if side == OrderSide.buy else "TTTC0011U"
        return "VTTC0012U" if side == OrderSide.buy else "VTTC0011U"

    @staticmethod
    def _balance_tr_id(environment: BrokerEnvironment) -> str:
        if environment == BrokerEnvironment.live:
            return "TTTC8434R"
        return "VTTC8434R"

    @staticmethod
    def _order_division(payload: DomesticStockOrderRequest) -> str:
        if payload.order_kind == OrderKind.market:
            return "01"
        return "00"

    def _validate_supported_order_session(
        self,
        payload: DomesticStockOrderRequest,
        order_division: str,
    ) -> None:
        if not self._settings.kis_regular_session_only:
            return
        if payload.order_kind not in {OrderKind.limit, OrderKind.market}:
            return
        if order_division not in {"00", "01"}:
            return

        now = datetime.now(self.KST)
        in_weekday = now.weekday() < 5
        in_regular_session = (
            self.REGULAR_SESSION_START <= now.time() <= self.REGULAR_SESSION_END
        )
        if in_weekday and in_regular_session:
            return

        raise KisOrderValidationError(
            "현재 MetaServer는 국내주식 정규장 주문만 지원합니다. "
            "평일 09:00~15:30(KST)에 지정가/시장가 주문을 전송해 주세요. "
            f"현재 서버 기준 시간은 {now:%Y-%m-%d %H:%M:%S KST}입니다."
        )

    @staticmethod
    def _order_price(payload: DomesticStockOrderRequest, order_division: str) -> Decimal:
        if order_division == "01":
            return Decimal("0")
        return payload.price or Decimal("0")

    def _order_payload(
        self,
        *,
        credentials: KisCredentials,
        payload: DomesticStockOrderRequest,
        order_division: str,
        order_price: Decimal,
    ) -> dict[str, str]:
        data = {
            "CANO": credentials.account_no,
            "ACNT_PRDT_CD": credentials.product_code,
            "PDNO": payload.symbol,
            "ORD_DVSN": order_division,
            "ORD_QTY": str(payload.quantity),
            "ORD_UNPR": self._decimal_as_api_int(order_price),
        }
        if self._settings.kis_order_protocol == "modern":
            data["EXCG_ID_DVSN_CD"] = payload.exchange_code
            data["SLL_TYPE"] = payload.sell_type if payload.side == OrderSide.sell else ""
            data["CNDT_PRIC"] = (
                self._decimal_as_api_int(payload.condition_price)
                if payload.condition_price is not None
                else ""
            )
        return data

    @staticmethod
    def _order_response(
        *,
        payload: DomesticStockOrderRequest,
        env: BrokerEnvironment,
        tr_id: str,
        order_division: str,
        order_price: Decimal,
        request_payload: dict[str, Any],
        data: dict[str, Any],
        raw_output: dict[str, Any],
        dry_run: bool,
    ) -> DomesticStockOrderResponse:
        return DomesticStockOrderResponse(
            environment=env,
            side=payload.side,
            symbol=payload.symbol,
            quantity=payload.quantity,
            order_kind=payload.order_kind,
            order_division_code=order_division,
            price=order_price,
            tr_id=tr_id,
            dry_run=dry_run,
            broker_order_no=raw_output.get("ODNO"),
            broker_order_time=raw_output.get("ORD_TMD"),
            kis_message_code=data.get("msg_cd"),
            kis_message=data.get("msg1"),
            request_payload=KisClient._sanitize_order_payload(request_payload),
            raw_output=raw_output,
        )

    @staticmethod
    def _decode_json(response: httpx.Response) -> dict[str, Any]:
        try:
            data = response.json()
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {"data": data}

    @staticmethod
    def _parse_token_expiry(data: dict[str, Any]) -> datetime:
        raw = data.get("access_token_token_expired")
        if isinstance(raw, str):
            try:
                return datetime.strptime(raw, "%Y-%m-%d %H:%M:%S")
            except ValueError:
                pass
        expires_in = data.get("expires_in")
        try:
            seconds = int(expires_in)
        except (TypeError, ValueError):
            seconds = 24 * 60 * 60
        return datetime.now() + timedelta(seconds=seconds)

    @staticmethod
    def _decimal(value: Any) -> Decimal | None:
        if value is None or value == "":
            return None
        try:
            return Decimal(str(value).replace(",", ""))
        except (InvalidOperation, ValueError):
            return None

    @staticmethod
    def _decimal_as_api_int(value: Decimal | None) -> str:
        if value is None:
            return "0"
        return str(int(value))

    @staticmethod
    def _as_dict(value: Any) -> dict[str, Any]:
        return value if isinstance(value, dict) else {}

    @staticmethod
    def _as_list(value: Any) -> list[dict[str, Any]]:
        if not isinstance(value, list):
            return []
        return [item for item in value if isinstance(item, dict)]

    @staticmethod
    def _first_dict(value: Any) -> dict[str, Any]:
        if isinstance(value, dict):
            return value
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    return item
        return {}

    def _decimal_first(self, values: dict[str, Any], *keys: str) -> Decimal | None:
        for key in keys:
            parsed = self._decimal(values.get(key))
            if parsed is not None:
                return parsed
        return None

    @staticmethod
    def _context_value(data: dict[str, Any], summary: dict[str, Any], key: str) -> str:
        value = (
            data.get(key)
            or data.get(key.upper())
            or summary.get(key)
            or summary.get(key.upper())
        )
        return str(value or "")

    @staticmethod
    def _sanitize_order_payload(payload: dict[str, Any]) -> dict[str, Any]:
        sanitized = dict(payload)
        account_no = sanitized.get("CANO")
        if isinstance(account_no, str):
            sanitized["CANO"] = KisClient._mask_account(account_no)
        return sanitized

    @staticmethod
    def _mask_full_account(credentials: KisCredentials) -> str:
        return f"{KisClient._mask_account(credentials.account_no)}-{credentials.product_code}"

    @staticmethod
    def _mask_account(account_no: str) -> str:
        if len(account_no) <= 4:
            return "*" * len(account_no)
        return f"{account_no[:2]}****{account_no[-2:]}"


@lru_cache
def get_kis_client() -> KisClient:
    return KisClient(get_settings())
