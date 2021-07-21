pragma solidity >=0.5.0;

import "../../contracts/interfaces/IWETH.sol";

contract SymbolicWETH is IWETH {

    function deposit() external override payable { }

    function withdraw(uint256) external override { }

    function transfer(address recipient, uint256 amount) external override returns(bool) { }

    function balanceOf(address account) external override view returns (uint256) { }
}