# ConfigMgr and Intune Cleanup Scripts

Scripts to help clean up applications and updates published due to an issue on November 1, 2023. The issue was an old set of metadata being rereleased.

NOTE: These scripts will remove specific, targeted Patch My PC Published applications and their deployments! ConfigMgr Application deployments will not automatically be recreated when the Patch My PC Publisher syncs. For Intune App and Update assignments, only those defined via right-click options will be recreated when the app/updates are recreated, manual assignments will be lost.

___

The information contained in this online site is presented for general educational and information purposes only. The information contained in this site should not be considered exhaustive and the user should seek the advice of appropriate professionals.

In no event shall PMP or its employees be liable for any liability, loss, injury or risk (including, without limitation, incidental and consequential damages, personal injury/wrongful death, lost profits or damages) which is incurred or suffered as a direct or indirect result of the use of any of the material, advice, guidance or services on this site, whether based on warranty, contract, tort, or any other legal theory and whether or not it is is advised of the possibility of such damages.

### DISCLAIMER

Patch My PC provides scripts, macro, and other code examples for illustration only, without warranty either expressed or implied, including but not limited to the implied warranties of merchantability and/or fitness for a particular purpose. This script is provided 'AS IS' and Patch My PC does not guarantee that the following script, macro, or code can or should be used in any situation or that operation of the code will be error-free.
