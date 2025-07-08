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
    bytes32 public constant SERVICER_ROLE = keccak256("SERVICER_ROLE");

    struct Tranche {
        uint256 principal;        // outstanding principal
        uint256 couponBps;        // annual rate in basis points
        uint8   seniority;        // 0 = most senior
        uint256 accruedInterest;  // unpaid interest accrued since last waterfall
        uint256 cashAvailable;    // allocated cash ready for withdrawal
    }

    // underlying stablecoin (e.g. USDC)
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

    /**
     * @notice Creates a new tranche and mints the specified supply to the caller.
     * @dev Validates principal and supply are non-zero.
     */
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

        // mint full supply to admin
        _mint(msg.sender, id, supply, data);
        emit TrancheCreated(id, principal, couponBps, seniority, supply);
    }

    /**
     * @notice Batch-transfer tranche tokens to investors
     * @param id        Tranche token ID
     * @param investors Addresses to receive tokens
     * @param amounts   Corresponding token amounts per investor
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

    /**
     * @dev Sums an array of uint256 values
     */
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

        // pay senior‐most interest → principal, then next tranche, etc.
        for (uint8 s = 0; s < 255 && remaining > 0; ++s) {
            for (uint256 id = 0; id < nextTrancheId && remaining > 0; ++id) {
                Tranche storage t = tranches[id];
                if (t.seniority != s) continue;

                // interest
                uint256 payInt = t.accruedInterest <= remaining ? t.accruedInterest : remaining;
                t.accruedInterest -= payInt;
                t.cashAvailable  += payInt;
                remaining        -= payInt;

                // principal
                uint256 payPrin = t.principal <= remaining ? t.principal : remaining;
                t.principal     -= payPrin;
                t.cashAvailable += payPrin;
                remaining       -= payPrin;

                emit PaymentAllocated(id, payInt, payPrin);
            }
        }
        // any leftover = excess spread
        emit PaymentAllocated(type(uint256).max, 0, remaining); // log excess spread under pseudo-id
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