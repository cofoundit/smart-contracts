/*

  Copyright 2017 Cofound.it.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.4.13;

import "./Utils/ReentrancyHandlingContract.sol";
import "./Utils/Owned.sol";
import "./Interfaces/PriorityPassInterface.sol";
import "./Interfaces/ERC20TokenInterface.sol";

contract SeedCrowdsaleContract is ReentrancyHandlingContract, Owned {

  struct ContributorData {
    uint contributionAmount;
  }

  mapping(address => ContributorData) public contributorList;
  uint public nextContributorIndex;
  mapping(uint => address) public contributorIndexes;

  state public crowdsaleState = state.pendingStart;
  enum state { pendingStart, priorityPass, openedPriorityPass, crowdsaleEnded }

  uint public presaleStartTime;
  uint public presaleUnlimitedStartTime;
  uint public crowdsaleEndedTime;

  event PresaleStarted(uint blocktime);
  event PresaleUnlimitedStarted(uint blocktime);
  event CrowdsaleEnded(uint blocktime);
  event ErrorSendingETH(address to, uint amount);
  event MinCapReached(uint blocktime);
  event MaxCapReached(uint blocktime);
  event ContributionMade(address indexed contributor, uint amount);

  PriorityPassInterface priorityPassContract = PriorityPassInterface(0x0);

  uint public minCap;
  uint public maxP1Cap;
  uint public maxCap;
  uint public ethRaised;

  address public multisigAddress;

  uint nextContributorToClaim;
  mapping(address => bool) hasClaimedEthWhenFail;

  //
  // Unnamed function that runs when eth is sent to the contract
  // @payable
  //
  function() noReentrancy payable public {
    require(msg.value != 0);                                                    // Throw if value is 0
    require(crowdsaleState != state.crowdsaleEnded);                            // Check if crowdsale has ended

    bool stateChanged = checkCrowdsaleState();                                  // Check blocks time and calibrate crowdsale state

    if (crowdsaleState == state.priorityPass) {
      if (priorityPassContract.getAccountActivity(msg.sender)) {                // Check if contributor is in priorityPass
        processTransaction(msg.sender, msg.value);                              // Process transaction and issue tokens
      } else {
        refundTransaction(stateChanged);                                        // Set state and return funds or throw
      }
    } else if (crowdsaleState == state.openedPriorityPass) {
      if (priorityPassContract.getAccountActivity(msg.sender)) {                // Check if contributor is in priorityPass
        processTransaction(msg.sender, msg.value);                              // Process transaction and issue tokens
      } else {
        refundTransaction(stateChanged);                                        // Set state and return funds or throw
      }
    } else {
      refundTransaction(stateChanged);                                          // Set state and return funds or throw
    }
  }

  //
  // @internal checks crowdsale state and emits events it
  // @returns boolean
  //
  function checkCrowdsaleState() internal returns (bool) {
    if (ethRaised == maxCap && crowdsaleState != state.crowdsaleEnded) {        // Check if max cap is reached
      crowdsaleState = state.crowdsaleEnded;
      MaxCapReached(block.timestamp);                                           // Close the crowdsale
      CrowdsaleEnded(block.timestamp);                                          // Raise event
      return true;
    }

    if (block.timestamp > presaleStartTime && block.timestamp <= presaleUnlimitedStartTime) { // Check if we are in presale phase
      if (crowdsaleState != state.priorityPass) {                               // Check if state needs to be changed
        crowdsaleState = state.priorityPass;                                    // Set new state
        PresaleStarted(block.timestamp);                                        // Raise event
        return true;
      }
    } else if (block.timestamp > presaleUnlimitedStartTime && block.timestamp <= crowdsaleEndedTime) {  // Check if we are in presale unlimited phase
      if (crowdsaleState != state.openedPriorityPass) {                         // Check if state needs to be changed
        crowdsaleState = state.openedPriorityPass;                              // Set new state
        PresaleUnlimitedStarted(block.timestamp);                               // Raise event
        return true;
      }
    } else {
      if (crowdsaleState != state.crowdsaleEnded && block.timestamp > crowdsaleEndedTime) {// Check if crowdsale is over
        crowdsaleState = state.crowdsaleEnded;                                  // Set new state
        CrowdsaleEnded(block.timestamp);                                        // Raise event
        return true;
      }
    }
    return false;
  }

  //
  // @internal determines if return eth or throw according to changing state
  // @param _stateChanged boolean message about state change
  //
  function refundTransaction(bool _stateChanged) internal {
    if (_stateChanged) {
      msg.sender.transfer(msg.value);
    } else {
      revert();
    }
  }

  //
  // Getter to calculate how much user can contribute
  // @param _contributor address of the contributor
  //
  function calculateMaxContribution(address _contributor) constant returns (uint maxContribution) {
    uint maxContrib;

    if (crowdsaleState == state.priorityPass) {                                 // Check if we are in priority pass
      maxContrib = priorityPassContract.getAccountLimit(_contributor) - contributorList[_contributor].contributionAmount;

	    if (maxContrib > (maxP1Cap - ethRaised)) {                                // Check if max contribution is more that max cap
        maxContrib = maxP1Cap - ethRaised;                                      // Alter max cap
      }

    } else {
      maxContrib = maxCap - ethRaised;                                          // Alter max cap
    }
    return maxContrib;
  }

  //
  // Return if there is overflow of contributed eth
  // @internal processes transactions
  // @param _contributor address of an contributor
  // @param _amount contributed amount
  //
  function processTransaction(address _contributor, uint _amount) internal {
    uint maxContribution = calculateMaxContribution(_contributor);              // Calculate max users contribution
    uint contributionAmount = _amount;
    uint returnAmount = 0;

	  if (maxContribution < _amount) {                                            // Check if max contribution is lower than _amount sent
      contributionAmount = maxContribution;                                     // Set that user contributes his maximum alowed contribution
      returnAmount = _amount - maxContribution;                                 // Calculate how much he must get back
    }

    if (ethRaised + contributionAmount >= minCap && minCap > ethRaised) {
      MinCapReached(block.timestamp);
    } 

    if (contributorList[_contributor].contributionAmount == 0) {                // Check if contributor has already contributed
      contributorList[_contributor].contributionAmount = contributionAmount;    // Set their contribution
      contributorIndexes[nextContributorIndex] = _contributor;                  // Set contributors index
      nextContributorIndex++;
    } else {
      contributorList[_contributor].contributionAmount += contributionAmount;   // Add contribution amount to existing contributor
    }
    ethRaised += contributionAmount;                                            // Add to eth raised

    ContributionMade(msg.sender, contributionAmount);                           // Raise event about contribution

	  if (returnAmount != 0) {
      _contributor.transfer(returnAmount);                                      // Return overflow of ether
    } 
  }

  //
  // Recovers ERC20 tokens other than eth that are send to this address
  // @owner refunds the erc20 tokens
  // @param _tokenAddress address of the erc20 token
  // @param _to address to where tokens should be send to
  // @param _amount amount of tokens to refund
  //
  function salvageTokensFromContract(address _tokenAddress, address _to, uint _amount) onlyOwner public {
    ERC20TokenInterface(_tokenAddress).transfer(_to, _amount);
  }

  //
  // withdrawEth when minimum cap is reached
  // @owner sets contributions to withdraw
  //
  function withdrawEth() onlyOwner public {
    require(this.balance != 0);
    require(ethRaised >= minCap);

    pendingEthWithdrawal = this.balance;
  }


  uint public pendingEthWithdrawal;
  //
  // pulls the funds that were set to send with calling of
  // withdrawEth when minimum cap is reached
  // @multisig pulls the contributions to self
  //
  function pullBalance() public {
    require(msg.sender == multisigAddress);
    require(pendingEthWithdrawal > 0);

    multisigAddress.transfer(pendingEthWithdrawal);
    pendingEthWithdrawal = 0;
  }

  //
  // Users can claim their contribution if min cap is not raised
  // @contributor calls claim function
  //
  function claimEthIfFailed() public {
    require(block.timestamp > crowdsaleEndedTime && ethRaised < minCap);        // Check if crowdsale has failed
    require(contributorList[msg.sender].contributionAmount > 0);                // Check if contributor has contributed to crowdsaleEndedBlock
    require(!hasClaimedEthWhenFail[msg.sender]);                                // Check if contributor has already claimed his eth

    uint ethContributed = contributorList[msg.sender].contributionAmount;       // Get contributors contribution
    hasClaimedEthWhenFail[msg.sender] = true;                                   // Set that he has claimed

	  if (!msg.sender.send(ethContributed)) {                                     // Refund eth
      ErrorSendingETH(msg.sender, ethContributed);                              // If there is an issue raise event for manual recovery
    }
  }

  //
  // Owner can batch return contributors contributions(eth)
  // @owner returns contributions
  // @param _numberOfReturns number of returns to do in one transaction
  //
  function batchReturnEthIfFailed(uint _numberOfReturns) onlyOwner public {
    require(block.timestamp > crowdsaleEndedTime && ethRaised < minCap);        // Check if crowdsale has failed

    address currentParticipantAddress;
    uint contribution;

    for (uint cnt = 0; cnt < _numberOfReturns; cnt++) {
      currentParticipantAddress = contributorIndexes[nextContributorToClaim];   // Get next unclaimed participant

      if (currentParticipantAddress == 0x0) {
         return;                                                                // Check if all the participants were compensated
      }

      if (!hasClaimedEthWhenFail[currentParticipantAddress]) {                  // Check if participant has already claimed
        contribution = contributorList[currentParticipantAddress].contributionAmount; // Get contribution of participant
        hasClaimedEthWhenFail[currentParticipantAddress] = true;                // Set that he has claimed

        if (!currentParticipantAddress.send(contribution)) {                    // Refund eth
          ErrorSendingETH(currentParticipantAddress, contribution);             // If there is an issue raise event for manual recovery
        }
      }
      nextContributorToClaim += 1;                                              // Repeat
    }
  }

  //
  // If there were any issue with refund owner can withdraw eth at the end for manual recovery
  // @owner withdraws remaining funds
  //
  function withdrawRemainingBalanceForManualRecovery() onlyOwner public {
    require(this.balance != 0);                                                 // Check if there are any eth to claim
    require(block.timestamp > crowdsaleEndedTime);                              // Check if crowdsale is over
    require(contributorIndexes[nextContributorToClaim] == 0x0);                 // Check if all the users were refunded
    multisigAddress.transfer(this.balance);                                     // Withdraw to multisig for manual processing
  }

  //
  // Owner can set multisig address for crowdsale
  // @owner sets an address where funds will go
  // @param _newAddress
  //
  function setMultisigAddress(address _newAddress) onlyOwner public {
    multisigAddress = _newAddress;
  }

  //
  // Setter for the whitelist contract
  // @owner sets address of whitelist contract
  // @param address
  //
  function setPriorityPassContract(address _newAddress) onlyOwner public {
    priorityPassContract = PriorityPassInterface(_newAddress);
  }

  //
  // Getter for the whitelist contract
  // @returns white list contract address
  //
  function priorityPassContractAddress() constant public returns (address) {
    return address(priorityPassContract);
  }

  //
  // Before crowdsale starts owner can calibrate time of crowdsale stages
  // @owner sends new times for the sale
  // @param _presaleStartTime timestamp for sale limited start
  // @param _presaleUnlimitedStartTime timestamp for sale unlimited
  // @param _crowdsaleEndedTime timestamp for ending sale
  //
  function setCrowdsaleTimes(uint _presaleStartTime, uint _presaleUnlimitedStartTime, uint _crowdsaleEndedTime) onlyOwner public {
    require(crowdsaleState == state.pendingStart);                              // Check if crowdsale has started
    require(_presaleStartTime != 0);                                            // Check if any value is 0
    require(_presaleStartTime < _presaleUnlimitedStartTime);                    // Check if presaleUnlimitedStartTime is set properly
    require(_presaleUnlimitedStartTime != 0);                                   // Check if any value is 0
    require(_presaleUnlimitedStartTime < _crowdsaleEndedTime);                  // Check if crowdsaleEndedTime is set properly
    require(_crowdsaleEndedTime != 0);                                          // Check if any value is 0
    presaleStartTime = _presaleStartTime;
    presaleUnlimitedStartTime = _presaleUnlimitedStartTime;
    crowdsaleEndedTime = _crowdsaleEndedTime;
  }

  // Only for testing purposes, delete before deploy
  function killContract() onlyOwner{
    selfdestruct(msg.sender);
  }
}
