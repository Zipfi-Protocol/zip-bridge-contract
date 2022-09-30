// SPDX-License-Identifier: MIT
pragma solidity 0.7.5;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../../../interfaces/IBurnableMintableERC677Token.sol";
import "../../../libraries/SafeMint.sol";
import "../../Ownable.sol";
import "./ZipbridgeFeeManager.sol";

/**
 * @title ZipbridgeFeeManagerConnector
 * @dev Connectivity functionality for working with ZipbridgeFeeManager contract.
 */
abstract contract ZipbridgeFeeManagerConnector is Ownable {
    using SafeERC20 for IERC20;
    using SafeMint for IBurnableMintableERC677Token;

    bytes32 internal constant FEE_MANAGER_CONTRACT = address(0); // keccak256(abi.encodePacked("feeManagerContract"))
    bytes32 internal constant HOME_TO_FOREIGN_FEE = address(0); // keccak256(abi.encodePacked("homeToForeignFee"))
    bytes32 internal constant FOREIGN_TO_HOME_FEE = address(0); // keccak256(abi.encodePacked("foreignToHomeFee"))

    event FeeDistributed(uint256 fee, address indexed token, bytes32 indexed messageId);
    event FeeDistributionFailed(address indexed token, uint256 fee);

    /**
     * @dev Updates an address of the used fee manager contract used for calculating and distributing fees.
     * @param _feeManager address of fee manager contract.
     */
    function setFeeManager(address _feeManager) external onlyOwner {
        _setFeeManager(_feeManager);
    }

    /**
     * @dev Retrieves an address of the fee manager contract.
     * @return address of the fee manager contract.
     */
    function feeManager() public view returns (ZipbridgeFeeManager) {
        return ZipbridgeFeeManager(addressStorage[FEE_MANAGER_CONTRACT]);
    }

    /**
     * @dev Internal function for updating an address of the used fee manager contract.
     * @param _feeManager address of fee manager contract.
     */
    function _setFeeManager(address _feeManager) internal {
        require(_feeManager == address(0) || Address.isContract(_feeManager));
        addressStorage[FEE_MANAGER_CONTRACT] = _feeManager;
    }

    /**
     * @dev Internal function for calculating and distributing fee through the separate fee manager contract.
     * @param _feeType type of the fee, can be one of [HOME_TO_FOREIGN_FEE, FOREIGN_TO_HOME_FEE].
     * @param _isNative true, if distributed token is native to this side of the bridge.
     * @param _from address of the tokens sender, needed only if _feeType is HOME_TO_FOREIGN_FEE.
     * @param _token address of the token contract, for which fee should be processed.
     * @param _value amount of tokens bridged.
     * @return total amount of fee distributed.
     */
    function _distributeFee(
        bytes32 _feeType,
        bool _isNative,
        address _from,
        address _token,
        uint256 _value
    ) internal returns (uint256) {
        ZipbridgeFeeManager manager = feeManager();
        if (address(manager) != address(0)) {
            // Next line disables fee collection in case sender is one of the reward addresses.
            // It is needed to allow a 100% withdrawal of tokens from the home side.
            // If fees are not disabled for reward receivers, small fraction of tokens will always
            // be redistributed between the same set of reward addresses, which is not the desired behaviour.
            if (_feeType == HOME_TO_FOREIGN_FEE && manager.isRewardAddress(_from)) {
                return 0;
            }
            uint256 fee = manager.calculateFee(_feeType, _token, _value);
            if (fee > 0) {
                if (_feeType == HOME_TO_FOREIGN_FEE) {
                    // for home -> foreign direction, fee is collected using transfer(address,uint256) method
                    // if transfer to the manager contract fails, the transaction is reverted
                    IERC20(_token).safeTransfer(address(manager), fee);
                } else {
                    // for foreign -> home direction,
                    // fee is collected using transfer(address,uint256) method for native tokens,
                    // and using mint(address,uint256) method for bridged tokens.
                    // if transfer/mint to the manager contract fails, the message still will be processed, but without fees
                    bytes4 selector = _isNative ? IERC20.transfer.selector : IBurnableMintableERC677Token.mint.selector;
                    (bool status, bytes memory returnData) =
                        _token.call(abi.encodeWithSelector(selector, manager, fee));
                    if (!status) {
                        emit FeeDistributionFailed(_token, fee);
                        return 0;
                    }
                    require(returnData.length == 0 || abi.decode(returnData, (bool)));
                }
                manager.distributeFee(_token);
            }
            return fee;
        }
        return 0;
    }

    function _getMinterFor(address _token) internal pure virtual returns (IBurnableMintableERC677Token);
}