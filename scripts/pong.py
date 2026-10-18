import curses
import random
import time

def main(stdscr):
    # Initialize curses
    curses.curs_set(0)  # Hide cursor
    stdscr.nodelay(1)   # Non-blocking input
    stdscr.timeout(100) # Refresh rate

    # Initialize game variables
    height, width = stdscr.getmaxyx()
    paddle_height = 5
    ball_symbol = 'O'
    paddle_symbol = '|'
    paddle_positions = [height//2 - paddle_height//2, height//2 - paddle_height//2]
    ball_pos = [height//2, width//2]
    ball_vel = [0, 0]

    # Initialize scores
    scores = [0, 0]

    # Draw paddles and ball
    def draw():
        stdscr.clear()
        # Draw paddles
        for i, pos in enumerate(paddle_positions):
            for j in range(paddle_height):
                try:
                    stdscr.addch(pos + j, i * (width - 1), paddle_symbol)
                except curses.error:
                    pass
        # Draw ball
        try:
            stdscr.addch(ball_pos[0], ball_pos[1], ball_symbol)
        except curses.error:
            pass
        # Draw scores
        stdscr.addstr(0, 0, f"Player 1: {scores[0]}  Player 2: {scores[1]}")
        stdscr.refresh()

    # Initialize ball
    def init_ball():
        global ball_pos, ball_vel
        ball_pos = [height//2, width//2]
        ball_vel = [random.choice([-1, 1]), random.choice([-1, 1])]

    init_ball()

    # Game loop
    while True:
        draw()

        # Get input
        key = stdscr.getch()

        # Player 1 controls (left paddle - left player)
        if key == ord('w'):
            paddle_positions[0] = max(0, paddle_positions[0] - 1)
        elif key == ord('s'):
            paddle_positions[0] = min(height - paddle_height, paddle_positions[0] + 1)

        # Player 2 controls (right paddle - right player)
        if key == ord('k'):
            paddle_positions[1] = max(0, paddle_positions[1] - 1)
        elif key == ord('m'):
            paddle_positions[1] = min(height - paddle_height, paddle_positions[1] + 1)

        # Quit game
        if key == ord('q'):
            break

        # Ball movement
        ball_pos[0] += ball_vel[0]
        ball_pos[1] += ball_vel[1]

        # Ball collision with top and bottom
        if ball_pos[0] <= 0 or ball_pos[0] >= height - 1:
            ball_vel[0] = -ball_vel[0]

        # Ball collision with paddles
        if (ball_pos[1] == 1 and
            paddle_positions[0] <= ball_pos[0] < paddle_positions[0] + paddle_height):
            ball_vel[1] = -ball_vel[1]

        if (ball_pos[1] == width - 2 and
            paddle_positions[1] <= ball_pos[0] < paddle_positions[1] + paddle_height):
            ball_vel[1] = -ball_vel[1]

        # Ball out of bounds (score)
        if ball_pos[1] <= 0:
            scores[1] += 1
            init_ball()
        elif ball_pos[1] >= width - 1:
            scores[0] += 1
            init_ball()

        time.sleep(0.05)  # Slow down the game

if __name__ == "__main__":
    curses.wrapper(main)
