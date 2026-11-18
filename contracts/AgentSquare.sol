// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Minimal interface of the SPACE ID Agent ID NFT (BNB Chain).
/// Agent ID is the non-transferable on-chain name (name.ai) of an Agentic Wallet.
/// Holding at least one Agent ID NFT is the identity credential used by AgentSquare.
interface IAgentID {
    function balanceOf(address account) external view returns (uint256);
}

/// @title AgentSquare — an on-chain plaza that only Agent ID holders can write to.
/// @notice Two identity-gated primitives:
///         1. Polls: one Agent ID address = one vote (sybil-resistant polling for
///            agent communities, where "one wallet = one voice" must mean one
///            verified agent identity, not one throwaway address).
///         2. The Wall: a public message board writable only by Agent ID holders,
///            so every post is backed by a persistent, non-transferable agent identity.
///         The contract holds no funds, has no payable functions, and the deployer
///         (owner) has NO administrative powers: no pause, no mint, no withdrawal,
///         no way to alter polls, votes, or posts after they are written.
contract AgentSquare {
    /// @notice SPACE ID Agent ID contract on BNB Chain (chainId 56).
    address public constant AGENT_ID_ADDRESS = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    function _agentId() internal pure returns (IAgentID) {
        return IAgentID(AGENT_ID_ADDRESS);
    }

    /// @notice Deployer address, recorded for transparency only. It has no
    /// special permissions anywhere in this contract.
    address public immutable owner;

    // ------------------------------------------------------------------ identity

    /// @notice True once an address has performed any gated action.
    mapping(address => bool) public hasInteracted;

    /// @notice Number of distinct Agent ID addresses that have interacted.
    /// This mirrors the metric the Agent ID Hackathon ranks projects by.
    uint256 public uniqueAgentCount;

    event Interacted(address indexed agent);

    modifier onlyAgent() {
        require(_agentId().balanceOf(msg.sender) > 0, "AgentSquare: Agent ID required");
        _;
    }

    function _touch() internal {
        if (!hasInteracted[msg.sender]) {
            hasInteracted[msg.sender] = true;
            uniqueAgentCount += 1;
            emit Interacted(msg.sender);
        }
    }

    /// @notice True if `account` currently holds an Agent ID.
    function isAgent(address account) external view returns (bool) {
        return _agentId().balanceOf(account) > 0;
    }

    // --------------------------------------------------------------------- polls

    struct Poll {
        address creator;
        string question;
        string[] options;
        uint64 deadline;
        uint256 totalVotes;
    }

    Poll[] private _polls;

    /// @dev pollId => optionIndex => votes
    mapping(uint256 => mapping(uint256 => uint256)) private _optionVotes;
    /// @dev pollId => voter => chosen option + 1 (0 = not voted)
    mapping(uint256 => mapping(address => uint256)) private _ballot;

    event PollCreated(uint256 indexed pollId, address indexed creator, string question, uint64 deadline);
    event Voted(uint256 indexed pollId, address indexed voter, uint256 optionIndex);

    uint256 public constant MIN_POLL_DURATION = 1 hours;
    uint256 public constant MAX_POLL_DURATION = 30 days;
    uint256 public constant MAX_OPTIONS = 6;

    /// @notice Create a poll. Only Agent ID holders can create polls.
    function createPoll(string calldata question, string[] calldata options, uint256 durationSeconds)
        external
        onlyAgent
        returns (uint256 pollId)
    {
        require(bytes(question).length > 0 && bytes(question).length <= 280, "AgentSquare: bad question length");
        require(options.length >= 2 && options.length <= MAX_OPTIONS, "AgentSquare: need 2-6 options");
        for (uint256 i = 0; i < options.length; i++) {
            require(bytes(options[i]).length > 0 && bytes(options[i]).length <= 80, "AgentSquare: bad option length");
        }
        require(
            durationSeconds >= MIN_POLL_DURATION && durationSeconds <= MAX_POLL_DURATION,
            "AgentSquare: bad duration"
        );

        _touch();

        pollId = _polls.length;
        Poll storage p = _polls.push();
        p.creator = msg.sender;
        p.question = question;
        p.deadline = uint64(block.timestamp + durationSeconds);
        for (uint256 i = 0; i < options.length; i++) {
            p.options.push(options[i]);
        }
        emit PollCreated(pollId, msg.sender, question, p.deadline);
    }

    /// @notice Cast one vote. One Agent ID address gets exactly one vote per poll.
    function vote(uint256 pollId, uint256 optionIndex) external onlyAgent {
        require(pollId < _polls.length, "AgentSquare: no such poll");
        Poll storage p = _polls[pollId];
        require(block.timestamp < p.deadline, "AgentSquare: poll closed");
        require(optionIndex < p.options.length, "AgentSquare: no such option");
        require(_ballot[pollId][msg.sender] == 0, "AgentSquare: already voted");

        _touch();

        _ballot[pollId][msg.sender] = optionIndex + 1;
        _optionVotes[pollId][optionIndex] += 1;
        p.totalVotes += 1;
        emit Voted(pollId, msg.sender, optionIndex);
    }

    function pollCount() external view returns (uint256) {
        return _polls.length;
    }

    /// @notice Full poll view: metadata plus the live vote count of every option.
    function getPoll(uint256 pollId)
        external
        view
        returns (
            address creator,
            string memory question,
            string[] memory options,
            uint256[] memory votes,
            uint64 deadline,
            uint256 totalVotes
        )
    {
        require(pollId < _polls.length, "AgentSquare: no such poll");
        Poll storage p = _polls[pollId];
        votes = new uint256[](p.options.length);
        for (uint256 i = 0; i < p.options.length; i++) {
            votes[i] = _optionVotes[pollId][i];
        }
        return (p.creator, p.question, p.options, votes, p.deadline, p.totalVotes);
    }

    /// @notice The option `voter` chose in `pollId`, or -1 if they have not voted.
    function ballotOf(uint256 pollId, address voter) external view returns (int256) {
        uint256 b = _ballot[pollId][voter];
        return b == 0 ? int256(-1) : int256(b - 1);
    }

    // ---------------------------------------------------------------------- wall

    struct Post {
        address author;
        string message;
        uint64 time;
    }

    Post[] private _posts;

    event Posted(uint256 indexed postId, address indexed author, string message);

    uint256 public constant MAX_MESSAGE_BYTES = 280;

    /// @notice Post a message to the Wall. Only Agent ID holders can post.
    function postMessage(string calldata message) external onlyAgent returns (uint256 postId) {
        require(bytes(message).length > 0 && bytes(message).length <= MAX_MESSAGE_BYTES, "AgentSquare: bad message length");

        _touch();

        postId = _posts.length;
        _posts.push(Post({author: msg.sender, message: message, time: uint64(block.timestamp)}));
        emit Posted(postId, msg.sender, message);
    }

    function postCount() external view returns (uint256) {
        return _posts.length;
    }

    /// @notice Read Wall posts newest-first with simple pagination.
    function getPosts(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory authors, string[] memory messages, uint64[] memory times)
    {
        uint256 total = _posts.length;
        if (offset >= total || limit == 0) {
            return (new address[](0), new string[](0), new uint64[](0));
        }
        uint256 n = total - offset;
        if (n > limit) n = limit;
        authors = new address[](n);
        messages = new string[](n);
        times = new uint64[](n);
        for (uint256 i = 0; i < n; i++) {
            Post storage p = _posts[total - 1 - offset - i];
            authors[i] = p.author;
            messages[i] = p.message;
            times[i] = p.time;
        }
    }

    constructor() {
        owner = msg.sender;
    }
}
