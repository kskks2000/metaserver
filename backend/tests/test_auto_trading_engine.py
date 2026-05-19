from __future__ import annotations

import unittest
from decimal import Decimal
from types import SimpleNamespace

from app.schemas.trading import BrokerEnvironment, OrderSide
from app.services import auto_trading_engine


class AutoTradingRiskChecksTest(unittest.TestCase):
    def setUp(self) -> None:
        self._original_daily_summary = (
            auto_trading_engine.auto_trading.daily_action_summary
        )
        auto_trading_engine.auto_trading.daily_action_summary = (
            lambda *args, **kwargs: {"order_count": 0, "order_amount": "0"}
        )

    def tearDown(self) -> None:
        auto_trading_engine.auto_trading.daily_action_summary = (
            self._original_daily_summary
        )

    def checks(
        self,
        daily_limit: str,
        loss_limit: str = "0",
        strategy_loss_limit: str | None = None,
        total_profit_loss: str | None = None,
    ) -> dict:
        portfolio = (
            None
            if total_profit_loss is None
            else SimpleNamespace(total_profit_loss=Decimal(total_profit_loss))
        )
        return auto_trading_engine._risk_checks(
            conn=object(),
            user_id="user-id",
            control={
                "max_single_order_amount": "10000",
                "max_daily_auto_order_amount": daily_limit,
                "max_daily_auto_loss_amount": loss_limit,
                "require_signal_approval": True,
            },
            strategy={
                "id": "strategy-id",
                "max_order_amount": "10000",
                "max_daily_loss_amount": strategy_loss_limit,
                "max_daily_trade_count": 2,
            },
            environment=BrokerEnvironment.paper,
            asset_class="crypto",
            side=OrderSide.buy,
            expected_amount=Decimal("5000"),
            quantity=Decimal("2.4"),
            portfolio=portfolio,
            symbol="KRW-XRP",
        )

    def test_zero_daily_order_limit_means_unset_for_risk_check(self) -> None:
        checks = self.checks("0")

        daily_check = next(
            item for item in checks["hard"] if item["key"] == "daily_amount_limit"
        )

        self.assertTrue(daily_check["passed"])

    def test_positive_daily_order_limit_still_blocks_excess_amount(self) -> None:
        checks = self.checks("1000")

        daily_check = next(
            item for item in checks["hard"] if item["key"] == "daily_amount_limit"
        )

        self.assertFalse(daily_check["passed"])

    def test_zero_daily_loss_limit_means_unset_for_risk_check(self) -> None:
        checks = self.checks("0", loss_limit="0")

        loss_check = next(
            item for item in checks["hard"] if item["key"] == "daily_loss_limit"
        )

        self.assertTrue(loss_check["passed"])

    def test_daily_loss_limit_blocks_when_portfolio_loss_exceeds_limit(self) -> None:
        checks = self.checks("0", loss_limit="8000", total_profit_loss="-9000")

        loss_check = next(
            item for item in checks["hard"] if item["key"] == "daily_loss_limit"
        )

        self.assertFalse(loss_check["passed"])

    def test_strategy_loss_limit_is_combined_with_control_loss_limit(self) -> None:
        checks = self.checks(
            "0",
            loss_limit="10000",
            strategy_loss_limit="8000",
            total_profit_loss="-9000",
        )

        loss_check = next(
            item for item in checks["hard"] if item["key"] == "daily_loss_limit"
        )

        self.assertFalse(loss_check["passed"])

    def test_paper_environment_does_not_require_signal_approval(self) -> None:
        self.assertFalse(
            auto_trading_engine._approval_required(
                {"require_signal_approval": True},
                BrokerEnvironment.paper,
            )
        )

    def test_live_environment_keeps_signal_approval_gate(self) -> None:
        self.assertTrue(
            auto_trading_engine._approval_required(
                {"require_signal_approval": True},
                BrokerEnvironment.live,
            )
        )

    def test_top_stock_rebalance_decision_uses_market_cap_gap(self) -> None:
        decision = auto_trading_engine._decision(
            {"strategy_type": "top_stock_rebalance"},
            {
                "symbol": "NVDA",
                "top_stock_rank": 1,
                "top_stock_name": "NVIDIA Corporation",
                "top_stock_market_cap_text": "5.38T",
                "top_stock_market_cap_gap_rate": "8.5",
                "trigger_change_rate": "3.0",
                "confirmation_rate": "0.5",
            },
            Decimal("-1.2"),
        )

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(decision["side"], OrderSide.buy)
        self.assertIn("NVDA", decision["reason"])

    def test_top_stock_rebalance_waits_when_lead_is_too_small(self) -> None:
        decision = auto_trading_engine._decision(
            {"strategy_type": "top_stock_rebalance"},
            {
                "symbol": "AAPL",
                "top_stock_rank": 1,
                "top_stock_name": "Apple Inc.",
                "top_stock_market_cap_text": "4.39T",
                "top_stock_market_cap_gap_rate": "1.0",
                "trigger_change_rate": "3.0",
                "confirmation_rate": "0.5",
            },
            Decimal("0.2"),
        )

        self.assertIsNone(decision)


if __name__ == "__main__":
    unittest.main()
