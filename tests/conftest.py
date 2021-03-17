import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def user(accounts):
    yield accounts[6]

@pytest.fixture
def gov(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 10 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x3f5CE5FBFe3E9af3971dD833D26bA9b5C936f0bE", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(gov, weth):
    weth_amout = 10 ** weth.decimals()
    gov.transfer(weth, weth_amout)
    yield weth_amout

@pytest.fixture
def vsp(accounts, user):
    amount = 1e20
    token_address = "0x1b40183EFB4Dd766f11bDa7A7c3AD8982e998421"
    vspContract = Contract(token_address)
    reserve = accounts.at("0x47c2807b21dcd776E49Cf7760cb5aCeAD97668CB", force=True)
    vspContract.transfer(user, amount, {"from": reserve})
    yield vspContract


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy

@pytest.fixture
def vWBTC():
    yield Contract("0x4B2e76EbBc9f2923d83F5FBDe695D8733db1a17B")

@pytest.fixture
def vVSP():
    yield Contract("0xbA4cFE5741b357FA371b506e5db0774aBFeCf8Fc")
