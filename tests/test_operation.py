import brownie
from brownie import Contract
from helpers import stratData,vaultData


def test_operation(accounts, token, vault, strategy, strategist, amount, user, vWBTC, chain, gov, vVSP, vsp):
    one_day = 86400
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    vaultData(vault, token)
    stratData(strategy, token, vWBTC, vVSP, vsp)

    # harvest 1
    strategy.harvest({"from": strategist})
    chain.mine(1)
    vaultData(vault, token)
    stratData(strategy, token, vWBTC, vVSP, vsp)
    assert strategy.estimatedTotalAssets()+1 >= amount # Won't match because we must account for withdraw fees

    # tend()
    # strategy.tend({"from": strategist})
    
    # Harvest 2: Allow rewards to be earned
    print("\n**Harvest 2**")
    chain.sleep(one_day)
    chain.mine(1)
    strategy.harvest({"from": strategist})
    vaultData(vault, token)
    stratData(strategy, token, vWBTC, vVSP, vsp)

    print("\nEst APR: ", "{:.2%}".format(
            ((vault.totalAssets() - amount) * 365) / (amount)
        )
    )

    # Harvest 3
    print("\n**Harvest 3**")
    chain.sleep(one_day)
    chain.mine(1)
    # vVSP.rebalance({"from": strategist}) # must be called from pool... this is hard to test.
    # strategy.toggleHarvestVvsp({"from":strategist}) # Dump VSP tokens this time
    strategy.harvest({"from": strategist})
    vaultData(vault, token)
    stratData(strategy, token, vWBTC, vVSP, vsp)

    # Current contract has rewards emissions ending on Mar 19, so we shouldnt project too far
    print("\nEst APR: ", "{:.2%}".format(
            ((vault.totalAssets() - amount) * 365/2) / (amount)
        )
    )

    # Harvest 4
    print("\n**Harvest 4**")
    chain.sleep(one_day)
    chain.mine(1)
    # vVSP.rebalance({"from": strategist}) # must be called from pool... this is hard to test.
    strategy.toggleHarvestVvsp({"from":strategist}) # Dump VSP tokens this time
    strategy.harvest({"from": strategist})
    vaultData(vault, token)
    stratData(strategy, token, vWBTC, vVSP, vsp)

    # Current contract has rewards emissions ending on Mar 19, so we shouldnt project too far
    print("\nEst APR: ", "{:.2%}".format(
            ((vault.totalAssets() - amount) * 365/3) / (amount)
        )
    )

    # Harves 5
    print("\n**Harvest 5**")
    chain.sleep(3600) # wait six hours for a profitable withdraw
    vault.withdraw(vault.balanceOf(user),user,61,{"from": user}) # Need more loss protect to handle 0.6% withdraw fee
    vaultData(vault, token)
    stratData(strategy, token, vWBTC, vVSP, vsp)
    assert token.balanceOf(user) > amount * 0.994 * .78 # Ensure profit was made after withdraw fee
    assert vault.balanceOf(vault.rewards()) > 0 # Check mgmt fee
    assert vault.balanceOf(strategy) > 0 # Check perf fee

def test_switch_dex(accounts, token, vault, strategy, strategist, amount, user, vWBTC, chain, gov, vVSP, vsp):
    originalDex = strategy.activeDex()
    strategy.toggleActiveDex({"from": gov})
    newDex = strategy.activeDex()
    assert originalDex != newDex

def test_emergency_exit(accounts, token, vault, strategy, strategist, amount, user, vVSP):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() + 1 >= amount

    # set emergency and exit
    strategy.setEmergencyExit()
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() < amount


def test_profitable_harvest(accounts, token, vault, strategy, strategist, amount, user, chain, vVSP, vWBTC):
    one_day = 86400
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    
    # harvest funds to strat
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets()+1 == amount

    # accrue profit + harvest
    chain.sleep(one_day)
    chain.mine(1)
    strategy.harvest({"from": strategist})
    
    assert strategy.estimatedTotalAssets()+1 > amount


def test_change_debt(gov, token, vault, strategy, strategist, amount, user, vWBTC, vVSP):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest({"from": strategist})

    assert strategy.estimatedTotalAssets()+1 == amount / 2

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets()+1 == amount

    # In order to pass this tests, you will need to implement prepareReturn.
    # TODO: uncomment the following lines.
    # vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    # assert token.balanceOf(strategy.address) == amount / 2


def test_sweep(gov, vault, strategy, token, amount, weth, weth_amout, vsp, user):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    vsp.transfer(strategy, 1e20, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # TODO: If you add protected tokens to the strategy.
    # Protected token doesn't work
    # with brownie.reverts("!protected"):
    #     strategy.sweep(strategy.protectedToken(), {"from": gov})

    with brownie.reverts("!want"):
         strategy.sweep(token.address, {"from": gov})
    
    with brownie.reverts("!authorized"):
         strategy.sweep(token.address, {"from": user})

    weth.transfer(strategy, weth.balanceOf(gov), {"from": gov})
    assert weth.address != strategy.want()
    strategy.sweep(weth, {"from": gov})
    assert weth.balanceOf(gov) > 0


def test_triggers(gov, vault, strategy, token, amount, weth, weth_amout, user, strategist):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    depositAmount = amount
    vault.deposit(depositAmount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest({"from": strategist})
    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)
