pragma solidity ^0.4.13;

contract IToken {
  function totalSupply() public constant returns (uint256 totalSupply);
  function mintTokens(address _to, uint256 _amount) public {}
}
