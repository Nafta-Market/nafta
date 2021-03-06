//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IFlashNFTReceiver} from "../interfaces/IFlashNFTReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {INafta} from "../interfaces/INafta.sol";
import {ILANDRegistry} from "./ILANDRegistry.sol";
import "hardhat/console.sol";

contract LandWrapper is IFlashNFTReceiver, ERC721, ERC721Holder {
  using SafeERC20 for IERC20;

  address public immutable landAddress;

  mapping(uint256 => address) nftOwners;

  constructor(address _landAddress) ERC721("Wrapped Decentraland LAND", "WLAND") {
    landAddress = _landAddress;
  }

  /// @notice Wraps LAND NFT
  /// @param tokenId The ID of the LAND NFT (minted wrappedNFT will have the same token ID)
  function wrap(uint256 tokenId) external {
    nftOwners[tokenId] = msg.sender;
    _safeMint(msg.sender, tokenId);
    IERC721(landAddress).safeTransferFrom(msg.sender, address(this), tokenId);
  }

  /// @notice Unwraps LAND NFT
  /// @param tokenId The ID of the LAND NFT (minted wrappedNFT has the same token ID)
  function unwrap(uint256 tokenId) external {
    require(nftOwners[tokenId] == msg.sender, "Only owner can unwrap NFT");
    require(ownerOf(tokenId) == msg.sender, "You must hold wrapped NFT to unwrap");
    _burn(tokenId);
    IERC721(landAddress).safeTransferFrom(address(this), msg.sender, tokenId);
  }

  /// @notice Wraps a LAND NFT, then adds to a Nafta pool
  /// @param landTokenId The ID of the LAND NFT (minted wrappedNFT has the same token ID)
  /// @param naftaAddress Address of Nafta
  /// @param flashFee - The fee user has to pay for a single rent (in WETH9) [Range: 0-4722.36648 ETH] (0 if flashrent is free)
  /// @param pricePerBlock - If renting longterm - this is the price per block (0 if not allowing renting longterm) [Range: 0-4722.36648 ETH]
  /// @param maxLongtermBlocks - Maximum amount of blocks for longterm rent [Range: 0-16777216]
  function wrapAndAddToNafta(
    uint256 landTokenId,
    address naftaAddress,
    uint256 flashFee,
    uint256 pricePerBlock,
    uint256 maxLongtermBlocks
  ) external {
    INafta nafta = INafta(naftaAddress);
    // get the id of the next minted naftaNFT
    uint256 naftaNFTId = nafta.lenderNFTCount() + 1;

    // wrap the LANDNFT in-place
    nftOwners[landTokenId] = msg.sender;
    _safeMint(address(this), landTokenId);
    IERC721(landAddress).safeTransferFrom(msg.sender, address(this), landTokenId);

    // approves wrapped LAND to nafta pool and adds it to the pool, this will mint a naftaNFT to this contract
    IERC721(address(this)).approve(naftaAddress, landTokenId);
    nafta.addNFT(address(this), landTokenId, flashFee, pricePerBlock, maxLongtermBlocks);

    // send a newly minted lender naftaNFT back to msg.sender
    IERC721(naftaAddress).safeTransferFrom(address(this), msg.sender, naftaNFTId);
  }

  /// @notice Removes a wrapped LAND NFT from a Nafta pool and returns the unwrapped NFT to the owner
  /// @param naftaAddress Address of Nafta
  /// @param landTokenId The ID of the LAND NFT, wrapped version also has the same ID
  /// @param naftaNFTId The ID of the Nafta NFT one receives when they added to the pool
  function unwrapAndRemoveFromNafta(
    address naftaAddress,
    uint256 landTokenId,
    uint256 naftaNFTId
  ) external {
    require(nftOwners[landTokenId] == msg.sender, "Only owner can unwrap NFT");

    // Transfer the nafta NFT from user to this contract
    IERC721(naftaAddress).safeTransferFrom(msg.sender, address(this), naftaNFTId);

    INafta nafta = INafta(naftaAddress);
    // removes the wrapped LAND NFT from nafta
    nafta.removeNFT(address(this), landTokenId);

    // burns the Wrapped LAND NFT
    _burn(landTokenId);

    // transfers the original LAND NFT back to the lender
    IERC721(landAddress).safeTransferFrom(address(this), msg.sender, landTokenId);
  }

  function changeUpdateOperator(uint256 tokenId, address newOperator) external {
    require(ownerOf(tokenId) == msg.sender, "Only holder of wrapped LAND can change UpdateOperator");
    ILANDRegistry(landAddress).setUpdateOperator(tokenId, newOperator);
  }

  function tokenURI(uint256 tokenId) public pure override returns (string memory) {
    return string.concat("https://api.decentraland.org/v2/contracts/0xf87e31492faf9a91b02ee0deaad50d51d56d5d4d/tokens/", toString(tokenId));
  }

  //////////////////////////////////////
  // IFlashNFTReceiver implementation
  //////////////////////////////////////

  event ExecuteCalled(address nftAddress, uint256 nftId, uint256 feeInWeth, address msgSender, bytes data);

  /// @notice Handles Nafta flashloan to Change LAND's UpdateOperator
  /// @dev This function is called by Nafta contract.
  /// @dev Nafta gives this reciever the NFT and expects it back, so we need to approve it here in the end.
  /// @dev But make sure you don't send any NFTs to this contract manually - that's not safe
  /// @param nftAddress  The address of NFT contract
  /// @param nftId  The id of NFT
  /// @param msgSender address of the account calling the flashloan function of Nafta contract
  /// @param data optional calldata passed into the function (can pass a newOperator address here)
  /// @return returns a boolean (true on success)
  function executeOperation(
    address nftAddress,
    uint256 nftId,
    uint256 feeInWeth,
    address msgSender,
    bytes calldata data
  ) external override returns (bool) {
    emit ExecuteCalled(nftAddress, nftId, feeInWeth, msgSender, data);
    require(nftAddress == address(this), "Only Wrapped LAND NFTs are supported");

    // Change LAND UpdateOperator
    if (data.length == 20) {
      // If data is passed - we assume an address there
      this.changeUpdateOperator(nftId, address(bytes20(data)));
    } else {
      // If it wasn't passed - we just make msgSender a new operator
      this.changeUpdateOperator(nftId, msgSender);
    }

    // Approve WrappedLAND NFT back to Nafta to return it
    this.approve(msg.sender, nftId);
    return true;
  }

  //////////////////////////////////////
  // Utilitary functions
  //////////////////////////////////////

  function toString(uint256 value) internal pure returns (string memory) {
    // Inspired by OraclizeAPI's implementation - MIT licence
    // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

    if (value == 0) {
      return "0";
    }
    uint256 temp = value;
    uint256 digits;
    while (temp != 0) {
      digits++;
      temp /= 10;
    }
    bytes memory buffer = new bytes(digits);
    while (value != 0) {
      digits -= 1;
      buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
      value /= 10;
    }
    return string(buffer);
  }
}
