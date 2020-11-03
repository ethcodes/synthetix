pragma solidity ^0.5.16;

pragma experimental ABIEncoderV2;

// Inheritance
import "./Owned.sol";
import "./Pausable.sol";
import "./MixinResolver.sol";

import "./SafeDecimalMath.sol";

import "./MultiCollateralState.sol";

import "./interfaces/IMultiCollateral.sol";

import "./interfaces/ISystemStatus.sol";
import "./interfaces/IFeePool.sol";
import "./interfaces/ISynth.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IExchangeRates.sol";


// Internal references

// Do as much as possible here. Then handle the eth/erc20 specifics in their contracts.

contract MultiCollateral is IMultiCollateral, Owned, MixinResolver, Pausable {
    /* ========== LIBRARIES ========== */

    using SafeMath for uint256;
    using SafeDecimalMath for uint256;
    
    uint256 internal constant SECONDS_IN_A_YEAR = 31536000;

    // The collateral that this contract stores
    bytes32 public collateralKey;

    bytes32 public sUSD = "sUSD";


    // ========== STATE VARIABLES ==========

    // Stores loans
    MultiCollateralState public multiCollateralState;

    // The synths that this contract can issue.
    mapping(bytes32 => bytes32) public synths;

    // ========== SETTER STATE VARIABLES ==========

    uint256 public minimumCollateralisation;
    
    // Interest rate per second for this collateral.
    uint256 public baseInterestRate;

    uint256 public liquidationPenalty;

    uint256 public debtCeiling;
    
    uint256 public issueFeeRate = (5 * SafeDecimalMath.unit()) / 1000;

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_SYSTEMSTATUS = "SystemStatus";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";

    bytes32[24] private addressesToCache = [CONTRACT_SYSTEMSTATUS, CONTRACT_EXRATES, CONTRACT_FEEPOOL];

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address payable _proxy,
        MultiCollateralState _multiCollateralState,
        address _owner,
        address _resolver,
        bytes32 _collateralKey, // synth associated with the collateral.
        bytes32[] memory _synths,
        uint _minimumCollateralisation,
        uint _interestRate,
        uint _liquidationPenalty,
        uint _debtCeiling
        ) public
        Owned(_owner)
        Pausable()
        MixinResolver(_resolver, addressesToCache) // what about adding the synth contract of the collateral
    {
        owner = msg.sender;
        multiCollateralState = _multiCollateralState;
        collateralKey = _collateralKey;
        // Set the vars
        setMinimumCollateralisation(_minimumCollateralisation);
        setBaseRate(_interestRate);
        setLiquidationPenalty(_liquidationPenalty);
        setDebtCeiling(_debtCeiling);

        for (uint i = 0; i < _synths.length; i++) {
            appendToAddressCache(_synths[i]);
            ISynth synth = ISynth(requireAndGetAddress(_synths[i], "Missing address"));
            synths[synth.currencyKey()] = _synths[i];
        }

        owner = _owner;

    }

    /* ========== VIEWS ========== */

    /* ---------- External Contracts ---------- */

    function systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(requireAndGetAddress(CONTRACT_SYSTEMSTATUS, "Missing SystemStatus address"));
    }

    function synth(bytes32 synth) internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(synth, "Missing synths address"));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES, "Missing ExchangeRates address"));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(requireAndGetAddress(CONTRACT_FEEPOOL, "Missing FeePool address"));
    }

    /* ---------- Public Views ---------- */

    function collateralRatio(Loan memory loan) public view returns (uint256 cratio) {
        // Any interest accrued prior is rolled up into loan amount
        // Do I need this line still?
        uint256 loanAmountWithAccruedInterest = loan.amount.add(loan.accruedInterest);

        // Wwe don't need to do this if we are in the same currency i.e sETH for ETH
        uint256 cvalue = loan.collateral.multiplyDecimal(exchangeRates().rateForCurrency(collateralKey));

        cratio = cvalue.divideDecimal(loanAmountWithAccruedInterest);
    }

    function issuanceRatio() public view returns (uint256 ratio) {
        // this rounds so you get slightly more rather than slightly less
        return SafeDecimalMath.unit().divideDecimalRound(minimumCollateralisation);
    }

    // The maximum number of synths issuable for this amount of collateral
    function maxLoan(uint256 collateralAmount, bytes32 currency) public view returns (uint256 max) {
        return issuanceRatio().multiplyDecimal(exchangeRates().effectiveValue(collateralKey, collateralAmount, currency));
    }

    /**
     * r = target issuance ratio
     * D = debt balance in sUSD
     * V = Collateral VALUE in sUSD
     * P = liquidation penalty
     * Calculates amount of synths = (D - V * r) / (1 - (1 + P) * r)
     */
    function liquidationAmount(Loan memory loan) public view returns (uint256 amount) {
        uint256 debtValue = loan.amount.add(loan.accruedInterest);
        uint256 collateralValue = loan.collateral.multiplyDecimal(exchangeRates().rateForCurrency(collateralKey));

        uint unit = SafeDecimalMath.unit();
        uint ratio = minimumCollateralisation;

        uint dividend = debtValue.sub(collateralValue.divideDecimal(ratio));
        uint divisor = unit.sub(unit.add(liquidationPenalty).divideDecimal(ratio));

        return dividend.divideDecimal(divisor);
    }

    // amount is the amount of synths we are liquidating
    function collateralRedeemed(bytes32 currency, uint256 amount) public view returns (uint256 collateral) {
        collateral = exchangeRates().effectiveValue(currency, amount, collateralKey);

        return collateral.multiplyDecimal(SafeDecimalMath.unit().add(liquidationPenalty));
    }

     function getFundingRate(bytes32 synth) public view returns (uint256 fundingRate) {

        // what is the risk here? if its ETH/sETH then we are safe
        // if (synth == collateralKey) {
        //     return baseInterestRate;
        // } else if (synth == sUSD) {
        //     // pay interest based on utilisation?
        //     // return baseInterestRate + utilisation;
        // } else {
        //     // here we are doing things that introduce skew.

        //     // this synth has a balance in the debt pool. we wish to charge
        //     // the overweighted side 
        //     // if (longs > shorts)
        // }

        // Here I can do things like, read the maker rate. Check synth skew. CHeck debt pool.

        // When I issue a certain synth says, 'sBTC', I want to check
        // the total amount of sBTC and iBTC in the market.
        // If sBTC > iBTC then they pay a positive rate r.
        // If iBTC < sBTC then they pay a negative rate r (or 0).

        // uint256 longs = issuer().totalIssuedSynths(synth, false); 

        // uint256 longs = 10000 * SafeDecimalMath.unit();

        // uint256 shorts = 5000 * SafeDecimalMath.unit();

        // // need to sup the bigger from the smaller and then note the sign.
        // uint256 skew = longs.sub(shorts);

        // uint256 proportionalSkew = skew.divideDecimal(longs.add(shorts));

        // uint256 maxSkewThreshold = SafeDecimalMath.unit();

        // uint256 maxRate = (10 * SafeDecimalMath.unit()) / 100;
        
        // uint256 fundingRate = proportionalSkew.divideDecimal(maxSkewThreshold).multiplyDecimal(maxRate);

        return baseInterestRate;
     }

    /* ---------- UTILITIES ---------- */
    
    // Check the account has enough of the synth to make the payment
    function _checkSynthBalance(address payer, bytes32 _synth, uint amount) internal view returns (bool) {
        require(IERC20(address(synth(synths[_synth]))).balanceOf(payer) >= amount, "Not enough synth balance");
    }

    function _checkLoanIsOpen(Loan memory _loan) internal pure {
        require(_loan.interestIndex > 0, "Loan already closed");
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /* ---------- SETTERS ---------- */

    function setMinimumCollateralisation(uint256 ratio) public onlyOwner {
        minimumCollateralisation = ratio;
        emit CollateralizationRatioUpdated(ratio);  
    }

    function setBaseRate(uint256 _interestRate) public onlyOwner {
        baseInterestRate = _interestRate;

        // would a change of this neccessitate an immediate call to AccrueInterest?

        emit InterestRateUpdated(baseInterestRate);
    }

    function setLiquidationPenalty(uint256 _liquidationPenalty) public onlyOwner {
        liquidationPenalty = _liquidationPenalty;
    }

    function setDebtCeiling(uint256 _debtCeiling) public onlyOwner {
        debtCeiling = _debtCeiling;
    }

    /* ---------- LOAN INTERACTIONS ---------- */

    function open(uint256 collateral, uint256 amount, bytes32 currency, bool short) internal CollateralRateNotInvalid returns (uint id) {
        systemStatus().requireIssuanceActive();

        // 3. Account has not reached max number of loans.
        // 5. Check new loan won't exceed supply cap.


        // require loanCurrecny either sUSD 
        require(synths[currency] > 0, "Not allowed to issue this synth");

        // 1. Collateral > minimum collateral size.
        require(collateral > 0, "Not enough collateral to create a loan");

        // 1. Calculate max possible loan from collateral provided
        uint256 max = maxLoan(collateral, currency);

        // this fee is denominated in the currency of the loan
        uint256 mintingFee = amount.multiplyDecimalRound(issueFeeRate);
        
        // 2. Reuire requested loan < max loan
        require(amount <= max, "Loan amount exceeds max borrowing power");

        // 3. Calculate the minting fee and subtract it from the loan amount
        uint256 loanAmountMinusFee = amount.sub(mintingFee);

        uint256 interestIndex = multiCollateralState.getRates(currency).length - 1;

        // Get a Loan ID
        id = multiCollateralState.incrementTotalLoans();
        // 4. Create the loan and save it to storage
        Loan memory loan = Loan({
            id: id,
            account: msg.sender,
            collateral: collateral, 
            currency: currency,
            amount: amount,
            short: short,
            mintingFee: mintingFee,
            accruedInterest: 0,
            // I don't think this works properly.
            interestIndex: interestIndex
        });

        // I don't think we should be accruing interest yet here.
        loan = accrueInterest(loan);

        // write the loan to storage
        multiCollateralState.createLoan(loan);

        // 5. Pay the minting fees to the fee pool
        _payFees(mintingFee, currency);
        
        // Issue synths to the borrower.

        if (short) {
            // require no open shorts for this synth by this account? Or do we not care about the implicit leverage?
            

            // Go back to the collateral currency
            loanAmountMinusFee = exchangeRates().effectiveValue(currency, loanAmountMinusFee, collateralKey);
            synth(synths[collateralKey]).issue(msg.sender, loanAmountMinusFee);
            multiCollateralState.incrementShorts(currency, amount);
        } else {
            synth(synths[currency]).issue(msg.sender, loanAmountMinusFee);
            multiCollateralState.incrementLongs(currency, amount);
        }

        // 8. Emit event
        emit LoanCreated(msg.sender, id, amount, collateral, currency);
    }

    function close(address borrower, uint256 loanID) internal returns(uint256 collateral) {
        systemStatus().requireIssuanceActive();

        // 1. Get the loan.
        Loan memory loan = multiCollateralState.getLoan(borrower, loanID);

        // 2. Check loan is open.
        _checkLoanIsOpen(loan); 

        // 3. Accrue interest on the loan.
        loan = accrueInterest(loan);

        // 4. Work out the total amount owing on the loan.
        uint256 amountOwing = loan.amount.add(loan.accruedInterest);

        // 5. Check they hvae enough balance to close the loan.
        _checkSynthBalance(loan.account, loan.currency, amountOwing);

        // 6. Burn the synths
        _burnSynths(borrower, loan.currency, amountOwing, loan.short);

        // 7. Pay fees
        _payFees(loan.accruedInterest, loan.currency);

        // 8. Liquidation
        // if (liquidation) {
        //     // Work out how much collateral to redeem
        //     uint256 totalCollateralLiquidated = collateralRedeemed(loan.currency, amountToLiquidate);

        //     msg.sender.transfer(totalCollateralLiquidated);
        // }

        // 9. 

        collateral = 0;

        // 5. Record loan as closed
        loan.interestIndex = 0;
        multiCollateralState.updateLoan(loan);

        emit LoanClosed(borrower, loanID, loan.accruedInterest);
    }

    // Deposits collateral to the specified loan
    function deposit(address account, uint256 id, uint256 amount) internal {
        systemStatus().requireIssuanceActive();

        // 1. They sent some value > 0
        require(amount > 0, "Deposit must be greater than 0");

        // 2. Get the loan
        Loan memory loan = multiCollateralState.getLoan(account, id);

        // 3. Check it is still open.
        _checkLoanIsOpen(loan);

        // 4. Accrue interest
        loan = accrueInterest(loan);

        // 5. Add the collateral
        loan.collateral = loan.collateral.add(amount);

        // 6. Store the loan
        multiCollateralState.updateLoan(loan);

        // 7. Emit the event
        emit CollateralDeposited(account, id, amount, loan.collateral);
    }

    // Withdraws collateral from the specified loan
    function withdraw(uint256 id, uint256 amount) internal {
        systemStatus().requireIssuanceActive();

        // 1. Check withdraw amount
        require(amount > 0 , "Amount to withdraw must be greater than 0");

        // 2. Get the loan.
        Loan memory loan = multiCollateralState.getLoan(msg.sender, id);

        // 2. Check loan exists and is open
        _checkLoanIsOpen(loan);

        // 3. Check amount is less than collateral.
        require(amount < loan.collateral, "Request exceeds total collateral");

        // 3. Accrue interest.
        loan = accrueInterest(loan);

        // 4. Subtract the collateral.
        loan.collateral = loan.collateral.sub(amount);

        // 5. Workout what the new c ratio would be.
        uint256 collateralRatioAfter = collateralRatio(loan);

        // 6. Check that the new amount does not put them under the minimum c ratio.
        require(collateralRatioAfter > minimumCollateralisation, "Collateral ratio below liquidation after withdraw");

        // 7. Store the loan.
        multiCollateralState.updateLoan(loan);
        
        // Emit the event.
        emit CollateralWithdrawn(msg.sender, id, amount, loan.collateral);
    }
    
    // What to do in the case that the payment takes the loan to 0. Need to close the loan.
    function liquidate(address borrower, uint256 id, uint256 payment) internal returns (uint256) {
        systemStatus().requireIssuanceActive();

        // 1. Check the payment amount.
        require(payment > 0, "Payment must be greater than 0");

        // 2. Get the loan.
        Loan memory loan = multiCollateralState.getLoan(borrower, id);

        // 3. Check the loan is open.
        _checkLoanIsOpen(loan);

        // 4. Check they have enough balance to make the payment.
        _checkSynthBalance(msg.sender, loan.currency, payment);

        // 5. Accrue interest.
        loan = accrueInterest(loan);
        
        // 6. Get the collateral ratio.
        uint256 collateralRatio = collateralRatio(loan);

        // 7 Check they are eligible for liquidation.
        require(collateralRatio < minimumCollateralisation, "Collateral ratio above liquidation ratio");

        // 8. Determine how much needs to be liquidated to fix their c ratio.
        uint256 liquidationAmount = liquidationAmount(loan);

        // 9. Only allow them to liquidate enough to fix the c ratio
        uint256 amountToLiquidate = liquidationAmount < payment ? liquidationAmount : payment;

        // 4. Work out the total amount owing on the loan.
        uint256 amountOwing = loan.amount.add(loan.accruedInterest);

        // We need to close the loan if this is the case.
        if (amountToLiquidate > amountOwing) {
            // cap amountToLiquidate here at amountOwing.
            // close the loan
        } else {

        }

        // 10. Process the payment to workout interest/principal split.
        loan = _processPayment(loan, amountToLiquidate);

        // 11. Work out how much collateral to redeem
        uint256 totalCollateralLiquidated = collateralRedeemed(loan.currency, amountToLiquidate);
        loan.collateral = loan.collateral.sub(totalCollateralLiquidated);

        // 12. burn sUSD from msg.sender for amount to liquidate
        _burnSynths(msg.sender, loan.currency, amountToLiquidate, loan.short);

        // 15. Store the loan.
        multiCollateralState.updateLoan(loan);

        // Emit the event
        emit LoanPartiallyLiquidated(
            borrower,
            id,
            msg.sender,
            amountToLiquidate,
            totalCollateralLiquidated
        );

        return totalCollateralLiquidated;
    }

    // Make a repayment on the loan
    // What to do in the case that repay amount >= loan.amount + loan.interest? Must close the loan.
    function repay(address borrower, address repayer, uint256 id, uint256 payment) internal {
        systemStatus().requireIssuanceActive();

        // 1. Check the payment amount.
        require(payment > 0, "Payment must be greater than 0");

        // 2. Get loan
        Loan memory loan = multiCollateralState.getLoan(borrower, id);

        // 2. Check the loan is still open
        _checkLoanIsOpen(loan);

        // 3. Check the spender has enough synths to make the repayment
        _checkSynthBalance(repayer, loan.currency, payment);

        // 4. Accrue interest.
        loan = accrueInterest(loan);

        // 4. Work out the total amount owing on the loan.
        uint256 amountOwing = loan.amount.add(loan.accruedInterest);

        // Repayment shouldnt work here. Is that right?
        require(payment < amountOwing, "Repayment would close loan. If you are the borrower then call close loan");

        // 5. Process the payment.
        loan = _processPayment(loan, payment);

        // 6. Burn synths from the payer
        _burnSynths(repayer, loan.currency, payment, loan.short);

        // 9. Store the loan
        multiCollateralState.updateLoan(loan);

        // 10. Emit the event.
        emit LoanRepaymentMade(borrower, repayer, id, payment, loan.amount);
    }

     // Update the cumulative interest rate for the currency that was interacted with.
     function accrueInterest(Loan memory loan) internal returns (Loan memory loanAfter) {

         loanAfter = loan;

         // 1. Get the rates time series for this currency.
         uint256[] memory rates = multiCollateralState.getRates(loan.currency);

         // 2. Get the timestamp of the last rate update.
         uint256 lastTime = multiCollateralState.rateLastUpdated(loan.currency);

         // 3. Get the last cumulative rate. F_last
         uint256 lastCumulativeRate = rates[rates.length - 1];

         // 4. Get the instantaneous rate. i
         uint256 instantaneousRate = getFundingRate(loan.currency);
        
         // 5. Get the time since we last updated the rate.
         uint256 timeDelta = (block.timestamp - lastTime) * SafeDecimalMath.unit();

         // 6. Get the time its been applied for. F
         uint256 cumulativeRate = instantaneousRate.multiplyDecimal(timeDelta);

         // 7. Get the latest cumulative rate. F_n+1 = F_n + F_last
         uint256 latestCumulative = lastCumulativeRate.add(cumulativeRate);

         // 8. Get the latest cumulative rate. F_n+1 = F_n + F_last
         uint256 entryCumulativeRate = rates[loan.interestIndex];
        
         uint256 interest = 0;

         if (loan.interestIndex != 0) {
            interest = loan.amount.multiplyDecimal(latestCumulative - entryCumulativeRate);
         }
        
         // set to 0 if loan is being opened

         // Update rates with the lastest cumulative rate. This also updates the time.
         multiCollateralState.updateRates(loan.currency, latestCumulative);
        
         // Update loan
         loanAfter.accruedInterest = loan.accruedInterest + interest;
         loanAfter.interestIndex = rates.length;
         multiCollateralState.updateLoan(loanAfter);

         return loanAfter;
     }

    // This function works out the amount of interest and principal after a repayment is made.
    // Will be used by repayLoan and liquidateLoan.
    function _processPayment(Loan memory loanBefore, uint256 payment)
        internal
        returns (Loan memory loanAfter)
    {
        loanAfter = loanBefore;
        uint256 interestPaid = 0;

        if (payment > 0 && loanBefore.accruedInterest > 0) {
            interestPaid = payment > loanBefore.accruedInterest ? loanBefore.accruedInterest : payment;
            loanAfter.accruedInterest = loanBefore.accruedInterest.sub(interestPaid);
            payment = payment.sub(interestPaid);

            _payFees(interestPaid, loanBefore.currency);
        }

        // If there is more payment left after the interest, pay down the principal.
        if (payment > 0) {
            loanAfter.amount = loanBefore.amount.sub(payment);
        }
    }  
    
    // Take an amount of fees and a currency they are denominated in. Coverts to sUSD if necessary and pay to the fee pool.
    function _payFees(uint amount, bytes32 _synth) internal {
        if (amount > 0)
            if (_synth != sUSD) {
                amount = exchangeRates().effectiveValue(_synth, amount, sUSD);
            }
            synth(synths[sUSD]).issue(feePool().FEE_ADDRESS(), amount);
            feePool().recordFeePaid(amount);

            // are you supposed to record this?
    }

    // Burn an amount of synths from the account
    function _burnSynths(address account, bytes32 _synth, uint amount, bool short) internal {
        synth(synths[_synth]).burn(account, amount);
        // decrement synths here.
        if (short) {
            multiCollateralState.decrementShorts(_synth, amount);
        } else {
            multiCollateralState.decrementLongs(_synth, amount);
        }
    }


    /* ========== MODIFIERS ========== */

    modifier CollateralRateNotInvalid() {
        require(!exchangeRates().rateIsInvalid(collateralKey), "Blocked as collateral rate is invalid");
        _;
    }

    // ========== EVENTS ==========
    event CollateralizationRatioUpdated(uint256 ratio);
    event LiquidationRatioUpdated(uint256 ratio);
    event InterestRateUpdated(uint256 interestRate);
    event IssueFeeRateUpdated(uint256 issueFeeRate);
    event IssueLimitUpdated(uint256 issueLimit);
    event MinLoanCollateralSizeUpdated(uint256 minLoanCollateralSize);
    event AccountLoanLimitUpdated(uint256 loanLimit);
    event LoanLiquidationOpenUpdated(bool loanLiquidationOpen);
    event LoanCreated(address indexed account, uint256 id, uint256 amount, uint256 collateral, bytes32 currency);
    event LoanClosed(address indexed account, uint256 id, uint256 feesPaid);
    event LoanLiquidated(address indexed account, uint256 id, address liquidator);
    event LoanPartiallyLiquidated(
        address indexed account,
        uint256 id,
        address liquidator,
        uint256 liquidatedAmount,
        uint256 liquidatedCollateral
    );
    event CollateralDeposited(address indexed account, uint256 id, uint256 collateralAmount, uint256 collateralAfter);
    event CollateralWithdrawn(address indexed account, uint256 id, uint256 amountWithdrawn, uint256 collateralAfter);
    event LoanRepaymentMade(address indexed account, address indexed repayer, uint256 id, uint256 repaidAmount, uint256 newLoanAmount);
}