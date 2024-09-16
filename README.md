<div align="center"> 

# Apprunner
<img src="/assets/apprunner.jpg" width="450" height="500">
</div>

The premise is simple: add commands to the yml file,run the program, get windows running your stuff! 

Apprunner will build N number of named Tmux windows running the commands you provide. If given a path (and not standalone), the window will be opened a that directory location.

# Prerequisites/Setup:
1. You DO need Tmux for this: https://github.com/tmux/tmux/wiki
2. Download the release for your system: https://github.com/BitlyTwiser/apprunner/releases
3. Fill out the yaml
example:
```
apps:
  - name: test1
    command: ping google.com
    standalone: true
    start_location: ./var/thing
  - name: test2
    command: ls -la
    standalone: false 
    start_location: /var/log
```
3. run `./apprunner <path_to_yaml_config>`
4. Terminal with your set commands will appear:
![Screenshot](/assets/screenshot1.png)
![Screenshot](/assets/screenshot2.png)

# How it works:
- This program executes tmux hooks to spawn a session, then add N number of windows to the session passing the keys to the given window. I.e. command -> window -> execute.
Example from the CLI:
```
tmux new-session -s test_sesh \; rename-window -t test_sesh:0 inner_window \; send-keys -t test_sesh:inner_window 'echo "hi" |base64' enter
```
This will spawn a new tmux session, create & rename the window, and run the command echoing hi to base64 encode.


## Roadmap:
- Multi-pane per window support. Instead of windows only, allow for user to select a split pane layout (i.e. split pane horizontal/vertical etc..)
- Save/Store runtime progress (like tmux resurrect)
