// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Very simple ERC-20 that can only be minted/burned by its deploying pool
contract TrancheToken is ERC20 {
    address public immutable pool;
    modifier onlyPool() {
        require(msg.sender == pool, "TrancheToken: only pool");
        _;
    }

    // Initialize ERC20
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        pool = msg.sender;
    }

    // Mint the tokens to a user and with specific address
    function mint(address to, uint256 amt) external onlyPool {
        _mint(to, amt);
    }

    // Burn tokens
    function burn(address from, uint256 amt) external onlyPool {
        _burn(from, amt);
    }
}

// Pools a set of loan-NFTs, issues N tranches (ERC-20),
// accepts later interest/principal deposits, and lets holders claim.
contract TranchePool {
    // Interface of the original TokenFactory, so we can read `value`.
    interface IFactory {
        function loans(uint256)
            external
            view
            returns (uint256 tokenId, uint256 value, address originator, address validator);
    }

    IFactory public immutable factory;     // The TokenFactory
    IERC721 public immutable loanNFT;      // the same as factory
    IERC20  public immutable stablecoin;   // e.g. USDC (must be approved)

    address public immutable originator;   // the only one who can pool & create tranches
    uint256 public immutable maturity;     // UNIX timestamp when principal may be deposited

    // Store tranche data
    struct Tranche {
        TrancheToken token;     // ERC-20 shares
        uint16 princPct;        // BPS of principal, sum across tranches = 10000
        uint16 intPct;          // BPS of interest, sum = 10000
    }

    Tranche[] public tranches;
    uint256[] public pooledLoans;               // token IDs pooled by originator
    mapping(uint256 => bool) public isPooled;

    // —————————————————————————————————————————————————————
    // Dividend-style distribution accounting (scaled by 1e18)
    mapping(uint256 => uint256) public magnifiedPrincPerShare;
    mapping(uint256 => uint256) public magnifiedIntPerShare;

    mapping(uint256 => mapping(address => uint256)) public withdrawnPrinc;
    mapping(uint256 => mapping(address => uint256)) public withdrawnInt;
    uint256 private constant MAG = 1e18;
    // —————————————————————————————————————————————————————

    // Events
    event LoanPooled(uint256 indexed tokenId);
    event TranchesCreated();
    event Purchased(uint256 indexed tranche, address indexed buyer, uint256 amt);
    event InterestDeposited(uint256 amt);
    event PrincipalDeposited(uint256 amt);
    event Claimed(uint256 indexed tranche, address indexed who, uint256 princAmt, uint256 intAmt);

    // Contract initialization
    constructor(
        address _factory,
        address _stablecoin,
        address _originator,
        uint256 _maturity
    ) {
        factory     = IFactory(_factory);
        loanNFT     = IERC721(_factory);
        stablecoin  = IERC20(_stablecoin);
        originator  = _originator;
        maturity    = _maturity;
    }

    // ————————————— Origination & Tranches —————————————

    // Originator pulls in their own loan-NFTs
    function poolLoans(uint256[] calldata tokenIds) external {
        require(msg.sender == originator, "only originator");
        for (uint i = 0; i < tokenIds.length; i++) {
            uint256 id = tokenIds[i];
            require(!isPooled[id], "already pooled");
            // verify this loan really belongs to the originator:
            (, uint256 val, , ) = factory.loans(id);
            require(val > 0, "unknown loan");
            loanNFT.transferFrom(msg.sender, address(this), id);
            pooledLoans.push(id);
            isPooled[id] = true;
            emit LoanPooled(id);
        }
    }

    // Once all desired loans are pooled, define N tranches.
    // principalPcts.sum==10000 && interestPcts.sum==10000
    function createTranches(
        string[] calldata names,
        string[] calldata symbols,
        uint16[] calldata principalPcts,
        uint16[] calldata interestPcts
    ) external {
        require(msg.sender == originator, "only originator");
        uint n = names.length;
        // Check inputs validity
        require(
            n > 0 &&
            symbols.length == n &&
            principalPcts.length == n &&
            interestPcts.length == n,
            "bad inputs"
        );
        uint256 sumP;
        uint256 sumI;
        // Calculate total principals and interest
        for (uint i = 0; i < n; i++) {
            sumP += principalPcts[i];
            sumI += interestPcts[i];
            // deploy each tranche token
            TrancheToken t = new TrancheToken(names[i], symbols[i]);
            tranches.push(Tranche({
                token: t,
                princPct: principalPcts[i],
                intPct: interestPcts[i]
            }));
        }
        require(sumP == 10000 && sumI == 10000, "must sum to 10000");
        emit TranchesCreated();

        // Now mint principal tokens 1:1 to this contract
        // totalPrincipal = sum of factory.loans(...) values
        uint256 totalPrincipal;
        for (uint i = 0; i < pooledLoans.length; i++) {
            (, uint256 v, , ) = factory.loans(pooledLoans[i]);
            totalPrincipal += v;
        }

        // Mint each tranche its share of principal
        for (uint i = 0; i < n; i++) {
            uint256 share = totalPrincipal * tranches[i].princPct / 10000;
            tranches[i].token.mint(address(this), share);
        }
    }

    // ————————————— Buying tranches —————————————

    // Anyone can buy any tranche 1:1 for `amt` units of stablecoin
    function buy(uint256 trancheIdx, uint256 amt) external {
        require(trancheIdx < tranches.length, "no such tranche");
        Tranche storage T = tranches[trancheIdx];
        require(T.token.balanceOf(address(this)) >= amt, "sold out");
        // pull stablecoin
        stablecoin.transferFrom(msg.sender, address(this), amt);
        // send tranche tokens
        T.token.transfer(msg.sender, amt);
        emit Purchased(trancheIdx, msg.sender, amt);
    }

    // ————————————— Deposits & Distributions —————————————

    // Called by originator automatically whenever interest is paid
    function depositInterest(uint256 amt) external {
        require(amt > 0, "zero");
        stablecoin.transferFrom(msg.sender, address(this), amt);
        emit InterestDeposited(amt);

        // waterfall by intPct
        uint256 n = tranches.length;
        for (uint i = 0; i < n; i++) {
            Tranche storage T = tranches[i];
            uint256 share = amt * T.intPct / 10000;
            uint256 supply = T.token.totalSupply();
            if (supply > 0) {
                magnifiedIntPerShare[i] += share * MAG / supply;
            }
        }
    }

    // After maturity, originator calls this to push back principal
    function depositPrincipal(uint256 amt) external {
        require(block.timestamp >= maturity, "too early");
        require(amt > 0, "zero");
        stablecoin.transferFrom(msg.sender, address(this), amt);
        emit PrincipalDeposited(amt);

        uint256 n = tranches.length;
        for (uint i = 0; i < n; i++) {
            Tranche storage T = tranches[i];
            uint256 share = amt * T.princPct / 10000;
            uint256 supply = T.token.totalSupply();
            if (supply > 0) {
                magnifiedPrincPerShare[i] += share * MAG / supply;
            }
        }
    }

    // ————————————— Claiming —————————————

    // Internal claim logic for one tranche and user
    function _claimOne(uint256 trancheIdx, address user) internal {
        Tranche storage T = tranches[trancheIdx];
        uint256 bal = T.token.balanceOf(user);
        if (bal == 0) return;

        // interest
        uint256 _int = (magnifiedIntPerShare[trancheIdx] * bal) / MAG;
        uint256 owedInt = _int - withdrawnInt[trancheIdx][user];
        if (owedInt > 0) {
            withdrawnInt[trancheIdx][user] += owedInt;
            stablecoin.transfer(user, owedInt);
        }

        // principal
        uint256 _pr = (magnifiedPrincPerShare[trancheIdx] * bal) / MAG;
        uint256 owedPr = _pr - withdrawnPrinc[trancheIdx][user];
        if (owedPr > 0) {
            withdrawnPrinc[trancheIdx][user] += owedPr;
            stablecoin.transfer(user, owedPr);
        }

        if (owedInt > 0 || owedPr > 0) {
            emit Claimed(trancheIdx, user, owedPr, owedInt);
        }
    }

    // Claims across all tranches for `msg.sender`
    function claimAll() external {
        uint256 n = tranches.length;
        for (uint256 i = 0; i < n; i++) {
            _claimOne(i, msg.sender);
        }
    }

    // Single‐tranche claim based on trancheIdx (index in the tranches array)
    function claim(uint256 trancheIdx) external {
        require(trancheIdx < tranches.length, "no such tranche");
        _claimOne(trancheIdx, msg.sender);
    }
}
