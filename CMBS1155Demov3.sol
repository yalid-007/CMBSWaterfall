// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CMBS1155 Waterfall Demo
 * @notice Extends CMBS1155 to include batch investor distribution and demo functions
 */
contract CMBS1155Demo is ERC1155Supply, AccessControl, Pausable {
    // --- DEMO ONLY: fast-forward time by an offset ---
    /**
     * @dev Advances `lastAccrual` by `secondsDelta`. Only for demo/testing.
     */
    function fastForward(uint256 secondsDelta) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lastAccrual += secondsDelta;
    }

    /**
     * @dev Convenience to jump roughly 6 months (≈182 days).
     */
    function fastForwardSixMonths() external onlyRole(DEFAULT_ADMIN_ROLE) {
        lastAccrual += 182 days;
    }

    bytes32 public constant SERVICER_ROLE = keccak256("SERVICER_ROLE");

    struct Tranche {
        uint256 principal;        // outstanding principal
        uint256 couponBps;        // annual rate in basis points
        uint8   seniority;        // 0 = most senior
        uint256 accruedInterest;  // unpaid interest accrued since last waterfall
        uint256 cashAvailable;    // allocated cash ready for withdrawal
    }

    IERC20 public immutable stable;
    uint256 public nextTrancheId;
    uint256 public lastAccrual;
    mapping(uint256 => Tranche) public tranches;

    // --- events ---
    event TrancheCreated(uint256 indexed id, uint256 principal, uint256 couponBps, uint8 seniority, uint256 supply);
    event PaymentAllocated(uint256 indexed id, uint256 interestPaid, uint256 principalPaid);
    event Distribution(uint256 indexed id, address indexed investor, uint256 amount);
    event Withdraw(address indexed investor, uint256 indexed id, uint256 amount);

    constructor(IERC20 _stable, string memory _uri) ERC1155(_uri) {
        stable = _stable;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        lastAccrual = block.timestamp;
    }

    // ------------------------------------------------------
    //  ADMIN / ISSUANCE
    // ------------------------------------------------------

    function createTranche(
        uint256 principal,
        uint256 couponBps,
        uint8 seniority,
        uint256 supply,
        bytes memory data
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(principal > 0, "INVALID_PRINCIPAL");
        require(supply > 0, "INVALID_SUPPLY");

        uint256 id = nextTrancheId;
        nextTrancheId = id + 1;

        tranches[id] = Tranche({
            principal: principal,
            couponBps: couponBps,
            seniority: seniority,
            accruedInterest: 0,
            cashAvailable: 0
        });

        _mint(msg.sender, id, supply, data);
        emit TrancheCreated(id, principal, couponBps, seniority, supply);
    }

    /**
     * @notice Batch-transfer tranche tokens to investors
     */
    function distributeToInvestors(
        uint256 id,
        address[] calldata investors,
        uint256[] calldata amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(investors.length == amounts.length, "ARRAY_LENGTH_MISMATCH");
        require(balanceOf(msg.sender, id) >= _totalAmount(amounts), "INSUFFICIENT_ADMIN_BAL");
        for (uint256 i = 0; i < investors.length; ++i) {
            safeTransferFrom(msg.sender, investors[i], id, amounts[i], "");
            emit Distribution(id, investors[i], amounts[i]);
        }
    }

    function _totalAmount(uint256[] memory arr) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < arr.length; ++i) {
            sum += arr[i];
        }
    }

    // ------------------------------------------------------
    //  INTEREST ACCRUAL
    // ------------------------------------------------------

    function _accrueAllInterest() internal {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return;
        lastAccrual = block.timestamp;

        for (uint256 id = 0; id < nextTrancheId; ++id) {
            Tranche storage t = tranches[id];
            if (t.principal == 0) continue;
            uint256 interest = (t.principal * t.couponBps * dt) / (365 days * 10_000);
            t.accruedInterest += interest;
        }
    }

    // ------------------------------------------------------
    //  WATERFALL & PAYMENT DISTRIBUTION
    // ------------------------------------------------------

    function depositAndDistribute(uint256 amount)
        external
        whenNotPaused
        onlyRole(SERVICER_ROLE)
    {
        require(stable.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");
        _accrueAllInterest();

        uint256 remaining = amount;
        for (uint8 s = 0; s < 255 && remaining > 0; ++s) {
            for (uint256 id = 0; id < nextTrancheId && remaining > 0; ++id) {
                Tranche storage t = tranches[id];
                if (t.seniority != s) continue;

                uint256 payInt = t.accruedInterest <= remaining ? t.accruedInterest : remaining;
                t.accruedInterest -= payInt;
                t.cashAvailable  += payInt;
                remaining        -= payInt;

                uint256 payPrin = t.principal <= remaining ? t.principal : remaining;
                t.principal     -= payPrin;
                t.cashAvailable += payPrin;
                remaining       -= payPrin;

                emit PaymentAllocated(id, payInt, payPrin);
            }
        }
        emit PaymentAllocated(type(uint256).max, 0, remaining);
    }

    // ------------------------------------------------------
    //  INVESTOR WITHDRAWALS
    // ------------------------------------------------------

    function withdraw(uint256 id, uint256 amount) external whenNotPaused {
        require(balanceOf(msg.sender, id) >= amount, "INSUFFICIENT_BAL");
        Tranche storage t = tranches[id];

        uint256 proRata = (t.cashAvailable * amount) / totalSupply(id);
        t.cashAvailable -= proRata;

        _burn(msg.sender, id, amount);
        require(stable.transfer(msg.sender, proRata), "STABLE_TRANSFER_FAILED");
        emit Withdraw(msg.sender, id, proRata);
    }

    // ------------------------------------------------------
    //  VIEW FUNCTIONS 
    // ------------------------------------------------------

    /// @notice Returns how much cash (principal + interest) is pending withdrawal for an investor on a tranche
    function pendingCash(address investor, uint256 id) external view returns (uint256) {
        uint256 bal = balanceOf(investor, id);
        if (bal == 0) return 0;
        Tranche storage t = tranches[id];
        // pro-rata share of yet-to-withdraw principal+interest already allocated
        return (t.cashAvailable * bal) / totalSupply(id);
    }

    /// @notice Returns the current state of a tranche
    function trancheState(uint256 id)
        external
        view
        returns (
            uint256 principal,
            uint256 accruedInterest,
            uint256 cashAvailable,
            uint256 couponBps,
            uint256 seniority,
            uint256 totalSupply_
        ) {
        Tranche storage t = tranches[id];
        principal = t.principal;
        accruedInterest = t.accruedInterest; // accrued up to last waterfall
        cashAvailable = t.cashAvailable;
        couponBps = t.couponBps;
        seniority = t.seniority;
        totalSupply_ = totalSupply(id);
    }

    // ------------------------------------------------------
    //  PAUSE / SWEEP
    // ------------------------------------------------------

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
    function sweep(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stable.transfer(to, amount), "SWEEP_FAILED");
    }

    // ------------------------------------------------------
    //  Overrides
    // ------------------------------------------------------
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
