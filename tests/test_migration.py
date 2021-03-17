# TODO: Add tests that show proper migration of the strategy to a newer one
#       Use another copy of the strategy to simulate the migration
#       Show that nothing is lost!


def test_migration(token, vault, strategy, amount, Strategy, strategist, gov, user):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.harvest({"from": strategist})
    tokenBalBefore = token.balanceOf(strategy.address)
    assert strategy.estimatedTotalAssets()+1 == amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault)
    strategy.migrate(new_strategy.address, {"from": gov})
    tokenBalAfter = token.balanceOf(strategy.address)
    assert new_strategy.estimatedTotalAssets()+1 >= amount
    assert strategy.estimatedTotalAssets() == 0
    

