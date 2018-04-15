pragma solidity ^0.4.17;

import "./ERC20.sol";
import "./SafeMath.sol";
import "./MultiSigWallet.sol";


contract UpgradeAgent {
    address public owner;
    bool public isUpgradeAgent;
    uint256 public originalSupply; // the original total supply of old tokens
    bool public upgradeHasBegun;
    function upgradeFrom(address _from, uint256 _value) public;
}

/// @title Time-locked vault of tokens allocated to SVT after 120 days
contract SVTVault {

    using SafeMath for uint256;
        // flag to determine if address is for a real contract or not
    bool public isSVTVault = false;

    SVTToken svtToken;
    address svtMultisig;
    uint256 unlockedAtBlockNumber;
    
    //Locked time. Vault coins will be lock
    uint256 public constant numBlocksLocked = 1110857;

    /// @notice Constructor function sets the SVT Multisig address and
    /// total number of locked tokens to transfer
    function SVTVault(address _svtMultisig) public {
        if (_svtMultisig == 0x0) revert();
        svtToken = SVTToken(msg.sender);
        svtMultisig = _svtMultisig;
        isSVTVault = true;
        unlockedAtBlockNumber = SafeMath.add(block.number, numBlocksLocked); // 120 days of blocks later
    }

    /// @notice Transfer locked tokens to SVT's multisig wallet
    function unlock() external {
        // Wait your turn!
        if (block.number < unlockedAtBlockNumber) revert();
        // Will fail if allocation (and therefore toTransfer) is 0.
        if (!svtToken.transfer(svtMultisig, svtToken.balanceOf(this))) revert();
    }

    // disallow payment this is for SVT not ether
    function () public { revert(); }

}

/// @title SVT crowdsale contract
contract SVTToken is ERC20 {
    using SafeMath for uint256;
    // flag to determine if address is for a real contract or not
    bool public isSVTToken = false;

    // Contract State 
    enum State {PreFunding, Funding, Success, Failure}

    // Token information
    string public constant name = "SMS Vote Token";
    string public constant symbol = "SVT";
    uint256 public constant decimals = 18;  // decimal places
    uint256 public constant crowdfundPercentOfTotal = 70;
    uint256 public constant vaultPercentOfTotal = 18;
    uint256 public constant svtPercentOfTotal = 12;
    uint256 public constant hundredPercent = 100;

    mapping (address => uint256) balances;
    mapping (address => mapping (address => uint256)) allowed;

    // Upgrade information
    address public upgradeMaster;
    UpgradeAgent public upgradeAgent;
    uint256 public totalUpgraded;

    // Crowdsale information
    bool public finalizedCrowdfunding = false;
    uint256 public fundingStartBlock; // crowdsale start block
    uint256 public fundingEndBlock; // crowdsale end block
    uint256 public constant tokensPerEtherPreFund = 1150; // SVT:ETH exchange rate
    uint256 public constant tokensPerEther = 1000; // SVT:ETH exchange rate
    uint256 public constant tokenCreationMax = 25000 ether * tokensPerEther;
    uint256 public constant tokenCreationMin = 2500 ether * tokensPerEther;
    // for testing on testnet
    

    address public svtMultisig;
    SVTVault public timeVault; // SVT's time-locked vault

    event Upgrade(address indexed _from, address indexed _to, uint256 _value);
    event Refund(address indexed _from, uint256 _value);
    event UpgradeAgentSet(address agent);

    // For mainnet, startBlock = 3445888, endBlock = 3618688
    //address must be multisigwallet
    function SVTToken(address _svtMultisig,
                        address _upgradeMaster,
                        uint256 _fundingStartBlock,
                        uint256 _fundingEndBlock) public {

        if (_svtMultisig == 0) revert();
        if (_upgradeMaster == 0) revert();
        if (_fundingStartBlock <= block.number) revert();
        if (_fundingEndBlock <= _fundingStartBlock) revert();
        isSVTToken = true;
        upgradeMaster = _upgradeMaster;
        fundingStartBlock = _fundingStartBlock;
        fundingEndBlock = _fundingEndBlock;
        timeVault = new SVTVault(_svtMultisig);
        if (!timeVault.isSVTVault()) revert();
        svtMultisig = _svtMultisig;
        if (!MultiSigWallet(svtMultisig).isMultiSigWallet()) revert();
    }

    function balanceOf(address who) public constant returns (uint) {
        return balances[who];
    }

    /// @notice Transfer `value` SVT tokens from sender's account
    /// `msg.sender` to provided account address `to`.
    /// @notice This function is disabled during the funding.
    /// @dev Required state: Success
    /// @param to The address of the recipient
    /// @param value The number of SVT to transfer
    /// @return Whether the transfer was successful or not
    function transfer(address to, uint256 value) public returns (bool ok) {
        if (getState() != State.Success) revert(); // Abort if crowdfunding was not a success.
        if (to == 0x0) revert();
        if (to == address(upgradeAgent)) revert();
        //if (to == address(upgradeAgent.newToken())) revert();
        uint256 senderBalance = balances[msg.sender];
        if (senderBalance >= value && value > 0) {
            senderBalance = SafeMath.sub(senderBalance, value);
            balances[msg.sender] = senderBalance;
            balances[to] = SafeMath.add(balances[to], value);
            Transfer(msg.sender, to, value);
            return true;
        }
        return false;
    }

    /// @notice Transfer `value` SVT tokens from sender 'from'
    /// to provided account address `to`.
    /// @notice This function is disabled during the funding.
    /// @dev Required state: Success
    /// @param from The address of the sender
    /// @param to The address of the recipient
    /// @param value The number of SVT to transfer
    /// @return Whether the transfer was successful or not
    function transferFrom(address from, address to, uint value) public returns (bool ok) {
        if (getState() != State.Success) revert(); // Abort if not in Success state.
        if (to == 0x0) revert();
        if (to == address(upgradeAgent)) revert();
        //if (to == address(upgradeAgent.newToken())) revert();
        if (balances[from] >= value &&
            allowed[from][msg.sender] >= value)
        {
            balances[to] = SafeMath.add(balances[to], value);
            balances[from] = SafeMath.sub(balances[from], value);
            allowed[from][msg.sender] = SafeMath.sub(allowed[from][msg.sender], value);
            Transfer(from, to, value);
            return true;
        } else { return false; }
    }

    /// @notice `msg.sender` approves `spender` to spend `value` tokens
    /// @param spender The address of the account able to transfer the tokens
    /// @param value The amount of wei to be approved for transfer
    /// @return Whether the approval was successful or not
    function approve(address spender, uint256 value) public returns (bool ok) {
        if (getState() != State.Success) revert(); // Abort if not in Success state.
        allowed[msg.sender][spender] = value;
        Approval(msg.sender, spender, value);
        return true;
    }

    /// @param owner The address of the account owning tokens
    /// @param spender The address of the account able to transfer the tokens
    /// @return Amount of remaining tokens allowed to spent
    function allowance(address owner, address spender) public constant returns (uint) {
        return allowed[owner][spender];
    }

    // Token upgrade functionality

    /// @notice Upgrade tokens to the new token contract.
    /// @dev Required state: Success
    /// @param value The number of tokens to upgrade
    function upgrade(uint256 value) external {
        if (getState() != State.Success) revert(); // Abort if not in Success state.
        if (upgradeAgent.owner() == 0x0) revert(); // need a real upgradeAgent address

        // Validate input value.
        if (value == 0) revert();
        if (value > balances[msg.sender]) revert();

        // update the balances here first before calling out (reentrancy)
        balances[msg.sender] = SafeMath.sub(balances[msg.sender], value);
        totalSupply = SafeMath.sub(totalSupply, value);
        totalUpgraded = SafeMath.add(totalUpgraded, value);
        upgradeAgent.upgradeFrom(msg.sender, value);
        Upgrade(msg.sender, upgradeAgent, value);
    }

    /// @notice Set address of upgrade target contract and enable upgrade
    /// process.
    /// @dev Required state: Success
    /// @param agent The address of the UpgradeAgent contract
    function setUpgradeAgent(address agent) external {
        if (getState() != State.Success) revert(); // Abort if not in Success state.
        if (agent == 0x0) revert(); // don't set agent to nothing
        if (msg.sender != upgradeMaster) revert(); // Only a master can designate the next agent
        if (address(upgradeAgent) != 0x0 && upgradeAgent.upgradeHasBegun()) revert(); // Don't change the upgrade agent
        upgradeAgent = UpgradeAgent(agent);
        // upgradeAgent must be created and linked to SVTToken after crowdfunding is over
        if (upgradeAgent.originalSupply() != totalSupply) revert();
        UpgradeAgentSet(upgradeAgent);
    }

    /// @notice Set address of upgrade target contract and enable upgrade
    /// process.
    /// @dev Required state: Success
    /// @param master The address that will manage upgrades, not the upgradeAgent contract address
    function setUpgradeMaster(address master) external {
        if (getState() != State.Success) revert(); // Abort if not in Success state.
        if (master == 0x0) revert();
        if (msg.sender != upgradeMaster) revert(); // Only a master can designate the next master
        upgradeMaster = master;
    }

    function setMultiSigWallet(address newWallet) external {
      if (msg.sender != svtMultisig) revert();
      MultiSigWallet wallet = MultiSigWallet(newWallet);
      if (!wallet.isMultiSigWallet()) revert();
      svtMultisig = newWallet;
    }

    // Crowdfunding:

    // don't just send ether to the contract expecting to get tokens
    function() public { revert(); }


    /// @notice Create tokens when funding is active.
    /// @dev Required state: Funding
    /// @dev State transition: -> Funding Success (only if cap reached)
    function create() payable external {
        // Abort if not in Funding Active state.
        // The checks are split (instead of using or operator) because it is
        // cheaper this way.
        State currentState = getState();
        uint256 createdTokens;
        if (currentState != State.Funding && currentState != State.PreFunding) revert();

        // Do not allow creating 0 or more than the cap tokens.
        if (msg.value == 0) revert();

        //PreFund 1150 per ether
        if(currentState == State.PreFunding)
            createdTokens = SafeMath.mul(msg.value, tokensPerEtherPreFund);
        //Fund 1000 per ether    
        if(currentState == State.Funding)
        // multiply by exchange rate to get newly created token amount
            createdTokens = SafeMath.mul(msg.value, tokensPerEther);

        // we are creating tokens, so increase the totalSupply
        totalSupply = SafeMath.add(totalSupply, createdTokens);

        // don't go over the limit!
        if (totalSupply > tokenCreationMax) revert();

        // Assign new tokens to the sender
        balances[msg.sender] = SafeMath.add(balances[msg.sender], createdTokens);

        // Log token creation event
        Transfer(0, msg.sender, createdTokens);
    }

    /// @notice Finalize crowdfunding
    /// @dev If cap was reached or crowdfunding has ended then:
    /// create SVT for the SVT Multisig and developer,
    /// transfer ETH to the SVT Multisig address.
    /// @dev Required state: Success
    function finalizeCrowdfunding() external {
        // Abort if not in Funding Success state.
        if (getState() != State.Success) revert(); // don't finalize unless we won
        if (finalizedCrowdfunding) revert(); // can't finalize twice (so sneaky!)

        // prevent more creation of tokens
        finalizedCrowdfunding = true;

        // Endowment: 18% of total goes to vault, timelocked for 6 months
        // uint256 vaultTokens = SafeMath.div(SafeMath.mul(totalSupply, vaultPercentOfTotal), hundredPercent);
        uint256 vaultTokens = SafeMath.div(SafeMath.mul(totalSupply, vaultPercentOfTotal), crowdfundPercentOfTotal);
        balances[timeVault] = SafeMath.add(balances[timeVault], vaultTokens);
        Transfer(0, timeVault, vaultTokens);

        // Endowment: 12% of total goes to svt for marketing and bug bounty
        uint256 svtTokens = SafeMath.div(SafeMath.mul(totalSupply, svtPercentOfTotal), crowdfundPercentOfTotal);
        balances[svtMultisig] = SafeMath.add(balances[svtMultisig], svtTokens);
        Transfer(0, svtMultisig, svtTokens);

        totalSupply = SafeMath.add(SafeMath.add(totalSupply, vaultTokens), svtTokens);

        // Transfer ETH to the SVT Multisig address.
        if (!svtMultisig.send(this.balance)) revert();
    }

    /// @notice Get back the ether sent during the funding in case the funding
    /// has not reached the minimum level.
    /// @dev Required state: Failure
    function refund() external {
        // Abort if not in Funding Failure state.
        if (getState() != State.Failure) revert();

        uint256 SVTValue = balances[msg.sender];
        if (SVTValue == 0) revert();
        balances[msg.sender] = 0;
        totalSupply = SafeMath.sub(totalSupply, SVTValue);

        uint256 ethValue = SafeMath.div(SVTValue, tokensPerEther); // SVTValue % tokensPerEther == 0
        Refund(msg.sender, ethValue);
        if (!msg.sender.send(ethValue)) revert();
    }

    /// @notice This manages the crowdfunding state machine
    /// We make it a function and do not assign the result to a variable
    /// So there is no chance of the variable being stale
    function getState() public constant returns (State) {
      // once we reach success, lock in the state
        if (finalizedCrowdfunding) 
            return State.Success;
        if (totalSupply < 3000 ether * tokensPerEther) 
            return State.PreFunding;
        else if (block.number <= fundingEndBlock && totalSupply < tokenCreationMax) 
            return State.Funding;
        else if (totalSupply >= tokenCreationMin) 
            return State.Success;
        else 
            return State.Failure;
    }
}
