/**
 * Deployment configuration for ShirushiCoin (SISC) v3.1.
 *
 * Copy to `scripts/sisc.config.ts` and fill in. EVERY value here is permanent: there is no
 * adminMint, no burn path, and DEFAULT_ADMIN_ROLE can never be moved, so a mistake in this
 * file can only be corrected by redeploying the token.
 */
export interface SiscConfig {
  roleHolders: {
    /** PERMANENT holder of DEFAULT_ADMIN_ROLE. Use a Safe, never a hot EOA. */
    admin: string;
    freezer: string;
    whitelistAdmin: string;
    miningAdmin: string;
    miner: string;
    /** Optional. Use the zero address for "no holder". */
    recorder: string;
  };
  /** Receives mining rewards. It is NOT auto-registered as an exchange address: it stays
   *  freezable, which is what keeps an abusive mint containable. Registering it later is an
   *  operational choice with a permanent cost - see docs/v3.1-security-notes.md S-5. */
  poolAccount: string;
  /** Migration supply recipients. Must be unique - the constructor rejects duplicates. */
  genesisHolders: string[];
  /** Amount per holder, in wei. Same length as genesisHolders, each > 0. */
  genesisAmounts: bigint[];
  /** Cumulative amount mined by the previous versions, in wei. Accounting only, not minted. */
  legacyMinedSupply: bigint;
  /** Chain id the deployment is intended for. Asserted against the RPC before the tx is sent.
   *  1 = Ethereum mainnet, 11155111 = Sepolia. */
  expectedChainId: number;
  /** Gas limit for the deploy tx. The constructor writes 100 reward-plan slots and runs an
   *  O(n^2) duplicate check over genesisHolders. MEASURED: 7,919,946 with one holder and
   *  11,512,077 with the maximum 100. deploy-sisc.ts rejects a value below the figure it
   *  computes for your holder count plus a 15% margin. */
  gasLimit: bigint;
}

const E = 10n ** 18n;

export const config: SiscConfig = {
  roleHolders: {
    admin: "0x0000000000000000000000000000000000000000",
    freezer: "0x0000000000000000000000000000000000000000",
    whitelistAdmin: "0x0000000000000000000000000000000000000000",
    miningAdmin: "0x0000000000000000000000000000000000000000",
    miner: "0x0000000000000000000000000000000000000000",
    recorder: "0x0000000000000000000000000000000000000000",
  },
  poolAccount: "0x0000000000000000000000000000000000000000",
  genesisHolders: [],
  genesisAmounts: [0n * E],
  legacyMinedSupply: 0n * E,
  expectedChainId: 1,
  gasLimit: 14_000_000n,
};
