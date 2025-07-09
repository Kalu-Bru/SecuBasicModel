// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

contract TokenFactory is ERC721URIStorage {

    // Save basic informations about the loan in a Struct
    struct Loan {
        uint256 tokenId;
        uint256 value;
        address originator;
        address validator;
    }

    // Map each tokenId to its corresponding Struct
    mapping (uint256 => Loan) public loans;

    // Use Counters to safely increment the tokenIds and ensure uniqueness
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    // Event signaling the minting of a token
    event LoanMinted(uint256 tokenId, address owner);

    // Initialization of the ERC721 standard
    constructor() ERC721("Token Scan", "TKS") {}

    // Mint tokens by giving in a tokenURI with its metadata, the loanValue
    // and the address of a validator
    function mint(
        string memory tokenURI,
        uint256 loanValue,
        address validator) 
        public returns (uint256) {

        // Creating new unique tokenId
        _tokenIds.increment();
        uint256 newItemId = _tokenIds.current();

        // Map tokenId to its Struct
        loans[newItemId] = {
            newItemId;
            loanValue;
            msg.sender;
            validator;
        }

        // Minting the token
        _mint(msg.sender, newItemId);

        // Assigning the token its metadata
        _setTokenURI(newItemId, tokenURI);

        // Emit and event to signal the minting 
        emit LoanMinted(newItemId, msg.sender);

        // Return new tokenId
        return newItemId;
    }

    // Check total supply of tokens minted
    function totalSupply() public view returns (uint256) {
        return _tokenIds.current();
    }
}
