// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

interface IPoolRewards {
    function claimReward(address) external;
    function claimable(address) external view returns (uint256);
    function pool() external view returns (address);
    function rewardPerToken() external view returns (uint256);
}

interface IVesperPool {
    function approveToken() external;
    function deposit(uint256) external;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalValue() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function getPricePerShare() external view returns (uint256);
    function withdrawFee() external view returns (uint256);
}

interface IUniswapV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // Vesper contracts: https://docs.vesper.finance/vesper-grow-pools/vesper-grow/audits#vesper-pool-contracts
    // Vesper vault strategies: https://medium.com/vesperfinance/vesper-grow-strategies-today-and-tomorrow-8bd7b907ba5
    address public constant vWBTC =         0x4B2e76EbBc9f2923d83F5FBDe695D8733db1a17B;
    address public constant uniswap =       0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant sushiswap =     0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address public activeDex =              0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address public constant vsp =           0x1b40183EFB4Dd766f11bDa7A7c3AD8982e998421;
    address public constant vVSP =          0xbA4cFE5741b357FA371b506e5db0774aBFeCf8Fc;
    address public constant poolRewards =   0x479A8666Ad530af3054209Db74F3C74eCd295f8D;
    address public constant weth =          0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address[] public vspPath;

    bool public useVvsp = true; // Allows us to control whether VSP rewards should be deposited to vVSP
    bool private harvestVvsp =  false; // private to hide visibility
    uint256 public _keepVSP =   3000; // 30%
    uint256 public constant DENOMINATOR = 10000;
    

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;

        IERC20(vsp).approve(sushiswap, uint256(-1));
        IERC20(vsp).approve(uniswap, uint256(-1));
        IERC20(vsp).approve(vVSP, uint256(-1));
        want.approve(vWBTC, uint256(-1));

        vspPath = new address[](3);
        vspPath[0] = vsp;
        vspPath[1] = weth;
        vspPath[2] = address(want);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyVesperUSDC";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        uint256 totalWant = 0;

        // Calculate VSP holdings
        uint256 totalVSP = IERC20(vsp).balanceOf(address(this));
        uint256 vspShares = IVesperPool(vVSP).balanceOf(address(this));
        if(vspShares > 0){
            uint256 pps = IVesperPool(vVSP).getPricePerShare();
            uint256 vaultBal = pps.mul(vspShares).div(1e18);
            totalVSP = totalVSP.add(vaultBal);
        }
        totalVSP = totalVSP.add(IPoolRewards(poolRewards).claimable(address(this)));
        if(totalVSP > 0){
            totalWant = totalWant.add(convertVspToWant(totalVSP));
        }
        
        // Calculate want
        totalWant = totalWant.add(want.balanceOf(address(this)));
        return totalWant.add(calcWantHeldInVesper());
    }

    function calcWantHeldInVesper() internal view returns (uint256 wantBalance) {
        wantBalance = 0;
        uint256 shares = IVesperPool(vWBTC).balanceOf(address(this));
        if(shares > 0){
            uint256 pps = morePrecisePricePerShare();
            uint256 withdrawableWant = pps.mul(shares).div(1e24);
            wantBalance = wantBalance.add(convertFrom18(withdrawableWant)); 
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        
        _debtPayment = _debtOutstanding; // default is to pay the full debt

        // Here we begin doing stuff to make our profits
        uint256 claimable = IPoolRewards(poolRewards).claimable(address(this));
        if(claimable > 0){
            IPoolRewards(poolRewards).claimReward(address(this));
        }
        // Check wheter this harvest should the vVSP vault
        if(harvestVvsp){
            withdrawAllVvsp();
            uint256 toSell = IERC20(vsp).balanceOf(address(this));
            if(toSell > 0){
                _sell(toSell);
            }
            harvestVvsp = false;
        }
        else{
            uint256 vspBal = IERC20(vsp).balanceOf(address(this));
            if(vspBal > 0){
                uint256 keepAmt = vspBal.mul(_keepVSP).div(DENOMINATOR);
                uint256 sellAmt = vspBal.sub(keepAmt);
                if(sellAmt > 0){
                    _sell(sellAmt);
                }
            }
        }

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 wantBalance = want.balanceOf(address(this));
        uint256 assets = wantBalance.add(calcWantHeldInVesper()); // Don't include kept vsp
        
        if(debt < assets){
            _profit = assets.sub(debt);
        }
        else{ // This is bad, would imply strategy is net negative
            _loss = debt.sub(assets);
        }

        // We want to free up enough to pay debt, without dipping into harvest profits
        uint256 toFree = _debtOutstanding.add(_profit);

        // Unlikely, but let's check if debt is high enought that 
        // we'll need to dip into vsp vault to pay debt
        if(toFree > calcWantHeldInVesper()){
            // Don't bother withdrawing "some", just yank it all
            withdrawAllVvsp();
            uint256 vspBalance = IERC20(vsp).balanceOf(address(this));
            if(vspBalance > 0){
                _sell(vspBalance);
                uint256 newBalance = want.balanceOf(address(this));
                wantBalance = newBalance;
                // Check if we have enough
                if(wantBalance > toFree){
                    toFree = 0;
                    _profit = wantBalance.sub(_debtPayment);
                }
                else{
                    toFree = toFree.sub(wantBalance);
                }
            }      
        }


        if(toFree > wantBalance){
            toFree = toFree.sub(wantBalance);

            (uint256 liquidatedAmount, uint256 withdrawalLoss) = withdrawSome(toFree);
            
            if(withdrawalLoss < _profit){
                _profit = _profit.sub(withdrawalLoss);
            }
            else{
                _loss = _loss.add(withdrawalLoss.sub(_profit));
                _profit = 0;
            }

            if(wantBalance < _profit){
                _profit = wantBalance;
                _debtPayment = 0;
            }
            else if (wantBalance < _debtPayment.add(_profit)){
                _debtPayment = wantBalance.sub(_profit);
            }
        }
    }

    function withdrawSome(uint256 _amount) internal returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 wantBalanceBefore = want.balanceOf(address(this));
        uint256 vaultBalance = IERC20(vWBTC).balanceOf(address(this));
        uint256 sharesToWithdraw = convertTo18(_amount
                .mul(1e24)
                .div(morePrecisePricePerShare()));
        if(vaultBalance > 0){
            IVesperPool(vWBTC).withdraw(sharesToWithdraw);
        }
        uint256 withdrawnAmount = want.balanceOf(address(this)).sub(wantBalanceBefore);
        if(withdrawnAmount >= _amount){
            _liquidatedAmount = _amount;
        }
        else{
            _liquidatedAmount = withdrawnAmount;
            _loss = _amount.sub(withdrawnAmount);
        }
    }

    function withdrawAllVvsp() internal {
        uint256 vaultBalance = IERC20(vVSP).balanceOf(address(this));
        if(vaultBalance > 0){
            IVesperPool(vVSP).withdraw(vaultBalance);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        
        uint256 wantBal = want.balanceOf(address(this));

        // In case we need to return want to the vault
        if (_debtOutstanding > wantBal) {
            return;
        }

        // Invest available want
        uint256 _wantAvailable = wantBal.sub(_debtOutstanding);
        if (_wantAvailable > 0) {
            IVesperPool(vWBTC).deposit(_wantAvailable);
        }

        // Check are we using the vsp vault? If so claim rewards and deposit
        if(useVvsp){
            if(IPoolRewards(poolRewards).claimable(address(this)) > 0) {
                IPoolRewards(poolRewards).claimReward(address(this));
                uint256 rewards = IERC20(vsp).balanceOf(address(this));
                if(rewards > 0){
                    IVesperPool(vVSP).deposit(rewards);
                }
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {

        uint256 wantBal = want.balanceOf(address(this));

        if (_amountNeeded > wantBal) {
            // Need more want to meet request. Must convert to 18 decimals
            (_liquidatedAmount, _loss) = withdrawSome(_amountNeeded.sub(wantBal));
        }
        _liquidatedAmount = Math.min(_amountNeeded, _liquidatedAmount.add(wantBal));
    }

    function _sell(uint256 _amount) internal {
        IUniswapV2Router(activeDex).swapExactTokensForTokens(_amount, uint256(0), vspPath, address(this), now);
    }

    function prepareMigration(address _newStrategy) internal override {
        // want is taken care of by baseStrategy, but we must send pool tokens to new strat
        if(IPoolRewards(poolRewards).claimable(address(this)) > 0){
            IPoolRewards(poolRewards).claimReward(address(this));
        }
        uint256 vWtbcBalance = IERC20(vWBTC).balanceOf(address(this));
        uint256 vspBalance = IERC20(vsp).balanceOf(address(this));
        uint256 vVspBalance = IERC20(vVSP).balanceOf(address(this));

        if(vWtbcBalance > 0){
            IERC20(vWBTC).transfer(_newStrategy, vWtbcBalance);
        }
        if(vspBalance > 0){
            IERC20(vsp).transfer(_newStrategy, vspBalance);
        }
        if(vVspBalance > 0){
            IERC20(vVSP).transfer(_newStrategy, vVspBalance);
        }
    }
    
    function convertVspToWant(uint256 _amount) internal view returns (uint256) {
        return IUniswapV2Router(activeDex).getAmountsOut(_amount, vspPath)[vspPath.length - 1];
    }

    function convertFrom18(uint256 _value) public pure returns (uint256) {
        return _value.div(10**10);
    }

    function convertTo18(uint256 _value) public pure returns (uint256) {
        return _value.mul(10**10);
    }
    
    function setKeepVSP(uint256 _amount) external onlyGovernance {
        require(_amount < DENOMINATOR, "cannot greater than denom!");
        _keepVSP = _amount;
    }

    function toggleUseVvsp() external onlyGovernance {
        useVvsp = !useVvsp;
    }

    function toggleHarvestVvsp() external {
        require(msg.sender == strategist || 
                msg.sender == governance() ||
                msg.sender == vault.management(),
            "!authorized"
        );
        harvestVvsp = true;
    }

    function toggleActiveDex() external onlyGovernance {
        if(activeDex == sushiswap){
            activeDex = uniswap;
        }
        else{
            activeDex = sushiswap;
        }
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = vsp;
        protected[1] = vWBTC;
    }

    function morePrecisePricePerShare() public view returns (uint256) {
        // We do this because Vesper's contract gives us a not-very-precise pps
        return IVesperPool(vWBTC).totalValue().mul(1e34).div(IVesperPool(vWBTC).totalSupply());
    }
}
