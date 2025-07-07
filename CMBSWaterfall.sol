// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CMBSWaterfall is ERC1155, Ownable, ReentrancyGuard {
    enum Tranche { A, B, C }

    mapping(Tranche => uint256) public maxPayout;
    mapping(Tranche => uint256) public received;
    mapping(Tranche => uint256) public totalSupply;
    
    // Track what each user has already claimed
    mapping(address => mapping(Tranche => uint256)) public claimed;

    event FundsReceived(uint256 amount);
    event FundsDistributed(uint256 trancheA, uint256 trancheB, uint256 trancheC);
    event Withdrawal(address indexed user, Tranche indexed tranche, uint256 amount);

    constructor(address initialOwner) 
    ERC1155("https://example.com/tranche/{id}.json") 
    Ownable(initialOwner) 
{
    maxPayout[Tranche.A] = 100 ether;
    maxPayout[Tranche.B] = 200 ether;

    _mint(initialOwner, uint256(Tranche.A), 1000, "");
    _mint(initialOwner, uint256(Tranche.B), 1000, "");
    _mint(initialOwner, uint256(Tranche.C), 1000, "");

    totalSupply[Tranche.A] = 1000;
    totalSupply[Tranche.B] = 1000;
    totalSupply[Tranche.C] = 1000;
}


    receive() external payable {
        distribute(msg.value);
    }

    function distribute(uint256 amount) internal {
        uint256 remaining = amount;
        uint256 trancheAAmount = 0;
        uint256 trancheBAmount = 0;
        uint256 trancheCAmount = 0;

        // Tranche A gets up to $100
        uint256 trancheAOwed = maxPayout[Tranche.A] - received[Tranche.A];
        if (trancheAOwed > 0 && remaining > 0) {
            trancheAAmount = remaining > trancheAOwed ? trancheAOwed : remaining;
            received[Tranche.A] += trancheAAmount;
            remaining -= trancheAAmount;
        }

        // Tranche B gets up to $200
        uint256 trancheBOwed = maxPayout[Tranche.B] - received[Tranche.B];
        if (trancheBOwed > 0 && remaining > 0) {
            trancheBAmount = remaining > trancheBOwed ? trancheBOwed : remaining;
            received[Tranche.B] += trancheBAmount;
            remaining -= trancheBAmount;
        }

        // Tranche C gets all remaining funds
        if (remaining > 0) {
            trancheCAmount = remaining;
            received[Tranche.C] += trancheCAmount;
        }

        emit FundsReceived(amount);
        emit FundsDistributed(trancheAAmount, trancheBAmount, trancheCAmount);
    }

    function withdraw(Tranche tranche) external nonReentrant {
        uint256 userBalance = balanceOf(msg.sender, uint256(tranche));
        require(userBalance > 0, "No tranche tokens");
        require(totalSupply[tranche] > 0, "No tokens in circulation");

        uint256 totalUserEntitled = (received[tranche] * userBalance) / totalSupply[tranche];
        uint256 alreadyClaimed = claimed[msg.sender][tranche];
        
        require(totalUserEntitled > alreadyClaimed, "Nothing to claim");
        
        uint256 payout = totalUserEntitled - alreadyClaimed;
        claimed[msg.sender][tranche] = totalUserEntitled;

        (bool success, ) = payable(msg.sender).call{value: payout}("");
        require(success, "Transfer failed");

        emit Withdrawal(msg.sender, tranche, payout);
    }

    function getClaimable(Tranche tranche, address user) external view returns (uint256) {
        uint256 userBalance = balanceOf(user, uint256(tranche));
        if (userBalance == 0 || totalSupply[tranche] == 0) return 0;
        
        uint256 totalEntitled = (received[tranche] * userBalance) / totalSupply[tranche];
        uint256 alreadyClaimed = claimed[user][tranche];
        
        return totalEntitled > alreadyClaimed ? totalEntitled - alreadyClaimed : 0;
    }

    function fundContract() external payable {
        distribute(msg.value);
    }

    // Allow minting more tokens (for additional investors)
    function mintTokens(address to, Tranche tranche, uint256 amount) external onlyOwner {
        _mint(to, uint256(tranche), amount, "");
        totalSupply[tranche] += amount;
    }

    // View functions for transparency
    function getTrancheInfo(Tranche tranche) external view returns (
        uint256 maxPayoutAmount,
        uint256 receivedAmount,
        uint256 supply
    ) {
        return (maxPayout[tranche], received[tranche], totalSupply[tranche]);
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}