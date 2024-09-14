# Apprunner
- The premise is simple, add stuff to the yml file. This *stuff* is commands, the location to run the command from (if not standalone) and the name.
- Run the code, and you will get N number of Tmux windows, with the name field from the yaml alloted to it, running the command you passed in.

# Prerequisites:
- You DO need Tmux for this: https://github.com/tmux/tmux/wiki
- Fill out the yaml
- $$$ run stuff

# How it works:
- This program executes tmux hooks to spawn a session, then add N number of windows to the session passing the keys to the given window. I.e. command -> window -> execute.
Example from the CLI:
```
tmux new-session -s test_sesh \; rename-window -t test_sesh:0 inner_window \; send-keys -t test_sesh:inner_window 'echo "hi" |base64' enter
```
This will spawn a new tmux session, create & rename the window, and run the command echoing hi to base64 encode.

