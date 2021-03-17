def test_revoke_strategy_from_vault(token, vault, strategy, amount, gov, user, strategist):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets()+1 == amount


def test_revoke_strategy_from_strategy(token, vault, strategy, amount, gov, user, strategist):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets()+1 == amount

    strategy.setEmergencyExit()
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() < 2 # Rounding error
    assert token.balanceOf(vault)+20 >= amount * 0.994 # Account for 0.6% withdrawal fee. Give .000020 extra for precision
